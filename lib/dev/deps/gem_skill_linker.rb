# frozen_string_literal: true

require "open3"
require "pathname"
require_relative "../skill_installer"
require_relative "bundler_repository"

module Dev
  module Deps
    # Links skills shipped inside the locked gem set into the project.
    #
    # A gem's skill is part of what installing that dependency means —
    # installing rspock without its skill would be an incomplete install,
    # exactly like installing it without its executables. So `dev up` /
    # `dev install-deps` finish by scanning the resolved (lockfile-matched)
    # gem set for skills/*/SKILL.md and linking each one project-scoped as
    # .agents/skills/gem-<gem>--<skill> (gitignored; an agent-neutral dir so
    # the mechanism isn't Cursor-locked). A skill-set change rides the same
    # staleness story as any dependency change: the lock digest changes, the
    # `dev up` nag fires, and the install refreshes the links.
    class GemSkillLinker
      LINK_PREFIX = "gem-"
      SKILLS_SUBDIR = "skills"
      AGENT_SKILLS_SUBDIRS = [".agents", "skills"].freeze

      # @param project_root [Pathname, String] repo root (Gemfile + link target)
      # @param skills_dir [Pathname, String, nil] override for tests; defaults
      #   to <project_root>/.agents/skills
      def initialize(project_root:, skills_dir: nil)
        @project_root = Pathname(project_root)
        @skills_dir = Pathname(skills_dir || @project_root.join(*AGENT_SKILLS_SUBDIRS))
        @skill_installer = SkillInstaller.new(skills_dir: @skills_dir)
      end

      # Scan the locked gem set for shipped skills and refresh the project's
      # links: install one per skill found, prune gem links whose gem left the
      # lock. Never raises — skill links are hygiene riding a dependency
      # install, and hygiene must not block correctness (failures are reported
      # on stderr).
      #
      # @return [void]
      def link_all
        return unless gemfile_path.exist?

        expected = expected_links
        expected.each { |name, skill_dir| @skill_installer.install(name, skill_dir) }
        prune_stale_links(expected.keys)
      rescue StandardError => e
        $stderr.puts "dev: warning: could not refresh gem skill links (#{e.message})."
      end

      private

      # The full link set the current lock implies: one entry per
      # skills/*/SKILL.md found in a locked gem's installed tree.
      #
      # @return [Hash{String => Pathname}] link name → skill directory
      def expected_links
        gem_roots.each_with_object({}) do |(gem_name, gem_root), links|
          (gem_root / SKILLS_SUBDIR).glob("*/#{SkillInstaller::SKILL_FILE}").sort.each do |skill_file|
            skill_dir = skill_file.dirname
            links["#{LINK_PREFIX}#{gem_name}--#{skill_dir.basename}"] = skill_dir
          end
        end
      end

      # Installed roots of the locked gems, paired with their gem names.
      # `bundle list --paths` gives the resolved install paths; the names come
      # from Gemfile.lock, so only lockfile-matched gems ever link (a stray
      # tree in the gem home is invisible here). A path matches a name when
      # its basename is `<name>-<version>` (or bare `<name>` for path gems);
      # the longest matching name wins so `minitest-reporters-1.6.1` pairs
      # with minitest-reporters, not minitest.
      #
      # @return [Array<Array(String, Pathname)>]
      def gem_roots
        names = locked_gem_names
        bundled_gem_paths.filter_map do |path|
          basename = path.basename.to_s
          name = names.select { |n| basename == n || basename.start_with?("#{n}-") }.max_by(&:length)
          [name, path] if name
        end
      end

      # Runs under the project's shadowenv for the same reason as
      # BundlerIntegration: the dev process's own PATH is the invoking
      # service's, which on headless boxes carries the wrong Ruby.
      #
      # @return [Array<Pathname>] install paths of every gem in the bundle
      def bundled_gem_paths
        out, err, status = Open3.capture3(
          { "BUNDLE_GEMFILE" => gemfile_path.to_s },
          "shadowenv", "exec", "--", "bundle", "list", "--paths",
          chdir: @project_root.to_s,
        )
        unless status.success?
          $stderr.puts "dev: warning: could not list bundled gems for skill links (#{err.strip})."
          return []
        end

        out.lines.filter_map do |line|
          stripped = line.strip
          Pathname(stripped) unless stripped.empty?
        end
      end

      # Gem names pinned in Gemfile.lock — every spec, transitive included
      # (a skill ships with its gem regardless of how the gem entered the
      # graph). Specs are the `name (version)` lines indented four spaces
      # under each source's `specs:` block; six-space lines are a spec's own
      # constraints and are skipped.
      #
      # @return [Array<String>]
      def locked_gem_names
        return [] unless lockfile_path.exist?

        names = []
        in_specs = false
        lockfile_path.read.each_line do |line|
          if line.match?(/^\s+specs:\s*$/)
            in_specs = true
          elsif in_specs && (match = line.match(/^ {4}(\S+) \([^)]+\)\s*$/))
            names << match[1]
          elsif in_specs && line.match?(/^\S/)
            in_specs = false
          end
        end
        names.uniq
      end

      # Remove gem links that no current gem accounts for (the gem left the
      # lock; its tree may still exist on disk, so broken-link pruning alone
      # would miss it). Only `gem-`-prefixed symlinks are candidates —
      # anything else in the dir is not ours.
      #
      # @param expected_names [Array<String>]
      # @return [void]
      def prune_stale_links(expected_names)
        return unless @skills_dir.directory?

        @skills_dir.children.each do |link|
          name = link.basename.to_s
          next unless link.symlink? && name.start_with?(LINK_PREFIX)

          @skill_installer.remove(name) unless expected_names.include?(name)
        end
      end

      # @return [Pathname]
      def gemfile_path
        @project_root / BundlerRepository::GEMFILE
      end

      # @return [Pathname]
      def lockfile_path
        @project_root / BundlerRepository::LOCKFILE
      end
    end
  end
end

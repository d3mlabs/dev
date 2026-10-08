# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "../skills/channel"
require_relative "../skills/layout"
require_relative "bundler_locker"
require_relative "shadowenv_exec"

module Dev
  module Deps
    # The skills shipped inside the locked gem set, as a skills channel.
    #
    # A gem's skill is part of what installing that dependency means —
    # installing rspock without its skill would be an incomplete install,
    # exactly like installing it without its executables. So `dev up` /
    # `dev deps install` finish by asking `Dev::Skills` to materialize this
    # channel: the resolved (lockfile-matched) gem set is scanned for
    # skills/*/SKILL.md and each one lands project-scoped as
    # .agents/skills/dev/gem/<gem>/<skill> (the dev-managed, self-ignoring
    # subtree of an agent-neutral dir, so the mechanism isn't Cursor-locked;
    # see Skills::Layout). A skill-set change rides the same
    # staleness story as any dependency change: the lock digest changes, the
    # `dev up` nag fires, and the install refreshes the links.
    #
    # This class owns *what* the gem skills are — which gem, which version,
    # where its tree is. Placing and pruning the links is the materializer's.
    class GemSkills
      extend T::Sig
      include Skills::Channel

      NAME = "gem"
      SKILLS_SUBDIR = "skills"

      sig { override.returns(Pathname) }
      attr_reader :root

      # @param project_root [Pathname, String] repo root (Gemfile + link target)
      # @param root [Pathname, String, nil] where the links land; defaults to
      #   the project-scoped discovery root (override for tests)
      # @param shadowenv_exec [ShadowenvExec] spawn seam for the project's Ruby toolchain
      sig do
        params(
          project_root: T.any(Pathname, String),
          root: T.nilable(T.any(Pathname, String)),
          shadowenv_exec: ShadowenvExec,
        ).void
      end
      def initialize(project_root:, root: nil, shadowenv_exec: ShadowenvExec.new(project_root: project_root))
        @project_root = T.let(Pathname(project_root), Pathname)
        @root = T.let(Pathname(root || Skills::Layout.project_root(@project_root)), Pathname)
        @shadowenv_exec = shadowenv_exec
      end

      sig { override.returns(String) }
      def name
        NAME
      end

      # A lockfile's set differs per project.
      sig { override.returns(T::Boolean) }
      def project_scoped?
        true
      end

      # One entry per skills/*/SKILL.md found in a locked gem's installed
      # tree. A project without a Gemfile declares nothing (and spawns no
      # bundler). A gem that resolves under the temp dir is still declared —
      # the installer declines to link it, and declaring it keeps a durable
      # link minted earlier from being pruned.
      sig { override.returns(T::Array[Skills::Entry]) }
      def entries
        return [] unless gemfile_path.exist?

        gem_roots.flat_map do |gem_name, gem_root|
          Skills::Layout.skill_dirs(gem_root / SKILLS_SUBDIR).map do |skill_dir|
            Skills::Entry.new(
              link_name: Skills::Layout.channel_link(NAME, gem_name, skill_dir.basename.to_s),
              source: skill_dir,
              package: gem_name,
              version: version_of(gem_name, gem_root),
            )
          end
        end
      end

      private

      # The installed version, read off the gem root's basename
      # (`<name>-<version>`); nil for a path gem whose root is bare.
      #
      # @param gem_name [String]
      # @param gem_root [Pathname]
      # @return [String, nil]
      sig { params(gem_name: String, gem_root: Pathname).returns(T.nilable(String)) }
      def version_of(gem_name, gem_root)
        basename = gem_root.basename.to_s
        return nil unless basename.start_with?("#{gem_name}-")

        basename.delete_prefix("#{gem_name}-")
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
      sig { returns(T::Array[[String, Pathname]]) }
      def gem_roots
        names = locked_gem_names
        bundled_gem_paths.filter_map do |path|
          basename = path.basename.to_s
          name = names.select { |n| basename == n || basename.start_with?("#{n}-") }.max_by(&:length)
          [name, path] if name
        end
      end

      # Goes through the ShadowenvExec seam for the same reason as
      # BundlerIntegration: the project's provisioned Ruby, with dev's own
      # and any harness's gem env scrubbed so a sandboxed session cannot
      # redirect the resolution into its ephemeral cache (dev#89).
      #
      # @return [Array<Pathname>] install paths of every gem in the bundle
      sig { returns(T::Array[Pathname]) }
      def bundled_gem_paths
        out, err, status = @shadowenv_exec.capture3(
          "bundle", "list", "--paths",
          env: { "BUNDLE_GEMFILE" => gemfile_path.to_s },
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
      sig { returns(T::Array[String]) }
      def locked_gem_names
        return [] unless lockfile_path.exist?

        names = []
        in_specs = T.let(false, T::Boolean)
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

      # @return [Pathname]
      sig { returns(Pathname) }
      def gemfile_path
        @project_root / BundlerLocker::GEMFILE
      end

      # @return [Pathname]
      sig { returns(Pathname) }
      def lockfile_path
        @project_root / BundlerRepository::LOCKFILE
      end
    end
  end
end

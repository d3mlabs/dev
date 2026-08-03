# frozen_string_literal: true

require "pathname"
require_relative "../deps/gem_skill_linker"
require_relative "../settings"
require_relative "../skill_installer"
require_relative "cache"
require_relative "invariants_renderer"
require_relative "layout"
require_relative "scaffolder"
require_relative "synchronizer"

module Dev
  module Learnings
    # Dispatch for `dev learnings …` — the explicit surface over the learnings
    # read path. Passive distribution rides dev's hook points (`dev up` /
    # `install-deps` / `dev plan`); these verbs are the manual override and
    # the inspection:
    #
    # - `sync`       — refresh the whole read path now (blocking): pull the
    #                  knowledge repo cache, relink skills (shipped, org, and
    #                  the project's gem skills), render + link the invariants
    #                  rule. Outside a project the machine-global parts run
    #                  and the project-scoped ones are skipped.
    # - `status`     — configured knowledge repo, cache location/age, and
    #                  what's rendered/linked per tier
    # - `invariants` — print the Tier-0 prompt block (the invariants section
    #                  extracted from the org index); the seam prompt-building
    #                  consumers like ai-flow shell out to
    # - `init`       — scaffold the canonical learnings layout (repo tier, or
    #                  the org knowledge-repo layout with --org); write-once —
    #                  an existing index is reported and left untouched, so
    #                  consumers (e.g. ai-flow's /learn) can call it
    #                  unconditionally before capturing
    #
    # RuntimeError subclasses throughout so the CLI boundary prints clean
    # `dev:` messages instead of backtraces.
    class Accessor
      class UsageError < RuntimeError; end

      # `dev learnings invariants` cannot produce the block: no knowledge repo
      # configured, no cache cloned yet, or no invariants section upstream.
      class InvariantsUnavailableError < RuntimeError; end

      # `dev learnings init` ran outside any project — there is no root to
      # scaffold into.
      class NoEnclosingProjectError < RuntimeError; end

      USAGE = <<~USAGE.strip
        usage: dev learnings <subcommand>
          dev learnings sync        refresh the whole read path now (blocking): knowledge repo cache, skill links, invariants render
          dev learnings status      configured knowledge repo, cache location/age, what's rendered and linked
          dev learnings invariants  print the always-on org invariants block (the Tier-0 prompt seam)
          dev learnings init        scaffold this repo's empty learnings index (write-once: an existing index is left untouched)
          dev learnings init --org  scaffold the org knowledge-repo layout (index.md + skills/) here, same write-once semantics
      USAGE

      # @param project_root [Pathname, String, nil] the enclosing project for
      #   the project-scoped artifacts (invariants link, gem skill links);
      #   nil when invoked outside any project — those parts are skipped
      # @param settings [Dev::Settings]
      # @param cache [Dev::Learnings::Cache, nil] override for tests; defaults
      #   to a cache over the configured knowledge repo (nil when unconfigured)
      # @param synchronizer [Dev::Learnings::Synchronizer, nil]
      # @param skill_installer [Dev::SkillInstaller] target of the shipped and
      #   org skill links; defaults to the user-global ~/.cursor/skills
      # @param gem_skill_linker [Dev::Deps::GemSkillLinker, nil] override for
      #   tests; defaults to the project's linker (nil outside a project)
      # @param renderer [Dev::Learnings::InvariantsRenderer]
      # @param scaffolder [Dev::Learnings::Scaffolder]
      def initialize(project_root:, settings: Dev::Settings.new, cache: nil, synchronizer: nil,
                     skill_installer: Dev::SkillInstaller.new, gem_skill_linker: nil,
                     renderer: InvariantsRenderer.new, scaffolder: Scaffolder.new)
        @project_root = project_root && Pathname(project_root)
        @settings = settings
        repo = settings.knowledge_repo
        @cache = cache || (repo && Cache.new(repo: repo))
        @synchronizer = synchronizer || Synchronizer.new(settings: settings, cache: @cache)
        @skill_installer = skill_installer
        @gem_skill_linker = gem_skill_linker ||
          (@project_root && Dev::Deps::GemSkillLinker.new(project_root: @project_root))
        @renderer = renderer
        @scaffolder = scaffolder
      end

      # Dispatch a `dev learnings …` invocation.
      #
      # @param args [Array<String>] argv after the "learnings" command
      # @param out [IO] output stream
      # @return [void]
      # @raise [UsageError] on an unrecognized invocation
      def run(args, out: $stdout)
        case args
        when ["sync"] then sync(out:)
        when ["status"] then status(out:)
        when ["invariants"] then invariants(out:)
        when ["init"] then init(out:)
        when ["init", "--org"] then init(out:, org: true)
        else raise UsageError, USAGE
        end
      end

      private

      # The whole read path, blocking, errors bubbling: shipped skill links,
      # the org tier (cache pull, org skill links, invariants render + project
      # link), and the project's gem skill relinks.
      #
      # @param out [IO]
      # @return [void]
      def sync(out:)
        @skill_installer.install_all(Dev::SkillInstaller::SHIPPED_SKILLS_DIR)
        @synchronizer.sync!(project_root: @project_root)
        @gem_skill_linker&.link_all
        out.puts "dev: learnings synced from #{@settings.knowledge_repo} (#{@cache.dir})."
        out.puts "dev: no enclosing project — skipped the invariants link and gem skill links." if @project_root.nil?
      end

      # @param out [IO]
      # @return [void]
      def status(out:)
        repo = @settings.knowledge_repo
        if repo.nil?
          out.puts "dev: no knowledge repo configured — add `knowledge_repo: <owner>/<repo>` " \
            "to #{@settings.config_path} (or set DEV_KNOWLEDGE_REPO)."
          return
        end

        out.puts "dev: knowledge repo: #{repo}"
        unless @cache.present?
          out.puts "dev: cache: #{@cache.dir} (not cloned yet — run `dev learnings sync`)."
          return
        end

        out.puts "dev: cache: #{@cache.dir} (refreshed #{format_age(Time.now - @cache.synced_at)} ago)."
        status_org_tier(out)
        status_project_tier(out)
      end

      # @param out [IO]
      # @return [void]
      # @raise [InvariantsUnavailableError] when the block cannot be produced
      def invariants(out:)
        if @cache.nil?
          raise InvariantsUnavailableError,
            "no knowledge repo configured — add `knowledge_repo: <owner>/<repo>` " \
            "to #{@settings.config_path} (or set DEV_KNOWLEDGE_REPO)."
        end
        unless @cache.present?
          raise InvariantsUnavailableError,
            "the knowledge repo cache has not been cloned yet — run `dev learnings sync`."
        end

        block = @renderer.prompt_block(@cache.index_file)
        raise InvariantsUnavailableError, "#{@cache.index_file} has no `## Invariants` section." if block.nil?

        out.puts block
      end

      # Scaffold the canonical learnings layout at the enclosing project's
      # root: the empty repo-tier index, or the org knowledge-repo layout
      # with org: true. The scaffold is write-once-committed — an existing
      # index makes this a reported no-op (exit 0), never an overwrite — so
      # consumers can call init unconditionally before capturing.
      #
      # @param out [IO]
      # @param org [Boolean] scaffold the org knowledge-repo layout instead
      #   of the repo tier
      # @return [void]
      # @raise [NoEnclosingProjectError] when run outside any project
      def init(out:, org: false)
        if @project_root.nil?
          raise NoEnclosingProjectError,
            "no enclosing project — run `dev learnings init` inside the repo to scaffold."
        end

        if org
          @scaffolder.scaffold_org(@project_root)
          out.puts "dev: scaffolded #{Layout.org_index_file(@project_root)} and " \
            "#{Layout.org_skills_dir(@project_root)}/ (the org knowledge-repo layout) — commit them."
        else
          @scaffolder.scaffold_repo(@project_root)
          out.puts "dev: scaffolded #{Layout.repo_index_file(@project_root)} " \
            "(this repo's empty always-on learnings index) — commit it."
        end
      rescue Scaffolder::IndexAlreadyExistsError => e
        out.puts "dev: #{e.message}"
      end

      # The org tier's rendered/linked state: the machine-side invariants
      # render and the org skill links.
      #
      # @param out [IO]
      # @return [void]
      def status_org_tier(out)
        rendered = @synchronizer.rendered_invariants_file
        out.puts(if rendered.file?
          "dev: invariants: rendered at #{rendered}."
        else
          "dev: invariants: not rendered (no invariants section in the index, or never synced)."
        end)
        out.puts "dev: org skills: #{org_skill_link_count} linked into #{@skill_installer.skills_dir}."
      end

      # The project tier's linked state: the invariants link and the gem skill
      # links, or a pointer when there is no enclosing project.
      #
      # @param out [IO]
      # @return [void]
      def status_project_tier(out)
        if @project_root.nil?
          out.puts "dev: project: none — run inside a repo to see its invariants link and gem skills."
          return
        end

        rules_file = @synchronizer.project_rules_file(@project_root)
        out.puts "dev: project invariants link: #{rules_file} (#{invariants_link_state(rules_file)})."
        out.puts "dev: gem skills: #{gem_skill_link_count} linked under #{gem_skills_dir}."
      end

      # @param rules_file [Pathname]
      # @return [String]
      def invariants_link_state(rules_file)
        if rules_file.symlink? && rules_file.readlink == @synchronizer.rendered_invariants_file
          "linked"
        elsif rules_file.symlink? || rules_file.file?
          "present but not dev's link — run `dev learnings sync`"
        else
          "missing — run `dev learnings sync`"
        end
      end

      # Org skill links are the entries in the skills dir pointing into the
      # cache's skills corpus.
      #
      # @return [Integer]
      def org_skill_link_count
        dir = @skill_installer.skills_dir
        return 0 unless dir.directory?

        corpus_prefix = "#{@cache.skills_dir}#{File::SEPARATOR}"
        dir.children.count { |link| link.symlink? && link.readlink.to_s.start_with?(corpus_prefix) }
      end

      # @return [Pathname]
      def gem_skills_dir
        @project_root.join(*Dev::Deps::GemSkillLinker::AGENT_SKILLS_SUBDIRS)
      end

      # @return [Integer]
      def gem_skill_link_count
        dir = gem_skills_dir
        return 0 unless dir.directory?

        dir.children.count do |link|
          link.symlink? && link.basename.to_s.start_with?(Dev::Deps::GemSkillLinker::LINK_PREFIX)
        end
      end

      # @param seconds [Numeric]
      # @return [String] a compact human age, e.g. "42s", "7m", "3h", "2d"
      def format_age(seconds)
        case seconds
        when 0...60 then "#{seconds.to_i}s"
        when 60...3600 then "#{(seconds / 60).to_i}m"
        when 3600...86_400 then "#{(seconds / 3600).to_i}h"
        else "#{(seconds / 86_400).to_i}d"
        end
      end
    end
  end
end

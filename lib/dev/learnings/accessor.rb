# typed: strict
# frozen_string_literal: true

require "pathname"
require "stringio"
require_relative "../settings"
require_relative "cache"
require_relative "invariants_renderer"
require_relative "layout"
require_relative "scaffolder"
require_relative "synchronizer"

module Dev
  module Learnings
    # Dispatch for `dev learnings …` — the explicit surface over the learnings
    # read path. Passive distribution rides dev's hook points (`dev up` /
    # `dev deps install` / `dev plan`); these verbs are the manual override and
    # the inspection:
    #
    # - `sync`       — refresh the org tier now (blocking): pull the knowledge
    #                  repo cache, materialize the org skills channel, render
    #                  + link the invariants rule. Outside a project the
    #                  machine-global parts run and the project link is
    #                  skipped. (Skill links across every channel are `dev
    #                  skills`' surface.)
    # - `status`     — configured knowledge repo, cache location/age, and
    #                  what's rendered/linked
    # - `invariants` — print the Tier-0 prompt block (the invariants section
    #                  extracted from the org index); the seam prompt-building
    #                  consumers like ai-flow shell out to
    # - `init`       — scaffold the canonical learnings layout (repo tier, or
    #                  the org knowledge-repo layout with --org); write-once —
    #                  an existing index is reported and left untouched, so
    #                  consumers (e.g. ai-flow's /learn) can call it
    #                  unconditionally before capturing
    #
    # One public method per verb; the `learnings` group in the command tree
    # routes `sync` / `status` / `invariants` / `init` to them, and the
    # leaves own the argv shape (flags, no stray arguments).
    #
    # RuntimeError subclasses throughout so the CLI boundary prints clean
    # `dev:` messages instead of backtraces.
    class Accessor
      extend T::Sig

      class UsageError < RuntimeError; end

      # `dev learnings invariants` cannot produce the block: no knowledge repo
      # configured, no cache cloned yet, or no invariants section upstream.
      class InvariantsUnavailableError < RuntimeError; end

      # `dev learnings init` ran outside any project — there is no root to
      # scaffold into.
      class NoEnclosingProjectError < RuntimeError; end

      # @param project_root [Pathname, String, nil] the enclosing project for
      #   the project-scoped invariants link; nil when invoked outside any
      #   project — the link is skipped
      # @param settings [Dev::Settings]
      # @param cache [Dev::Learnings::Cache, nil] override for tests; defaults
      #   to a cache over the configured knowledge repo (nil when unconfigured)
      # @param synchronizer [Dev::Learnings::Synchronizer, Dev::Learnings::UnconfiguredSynchronizer, nil]
      # @param renderer [Dev::Learnings::InvariantsRenderer]
      # @param scaffolder [Dev::Learnings::Scaffolder]
      sig do
        params(
          project_root: T.nilable(T.any(Pathname, String)),
          settings: Dev::Settings,
          cache: T.nilable(Cache),
          synchronizer: T.untyped,
          renderer: InvariantsRenderer,
          scaffolder: Scaffolder,
        ).void
      end
      def initialize(project_root:, settings: Dev::Settings.new, cache: nil, synchronizer: nil,
                     renderer: InvariantsRenderer.new, scaffolder: Scaffolder.new)
        @project_root = T.let(project_root && Pathname(project_root), T.nilable(Pathname))
        @settings = settings
        repo = settings.knowledge_repo
        @cache = T.let(cache || (repo && Cache.new(repo: repo)), T.nilable(Cache))
        # The synchronizer shares the accessor's cache (status/invariants
        # read it too); an unconfigured machine gets the null synchronizer.
        @synchronizer = T.let(
          synchronizer ||
            (@cache ? Synchronizer.new(settings: settings, cache: @cache) : UnconfiguredSynchronizer.new(settings: settings)),
          T.untyped,
        )
        @renderer = renderer
        @scaffolder = scaffolder
      end

      # `dev learnings sync`: the org tier, blocking, errors bubbling — cache
      # pull, org skills channel, invariants render + project link.
      #
      # @param out [IO, StringIO]
      # @return [void]
      sig { params(out: T.any(IO, StringIO)).void }
      def sync(out:)
        @synchronizer.sync!(project_root: @project_root)
        out.puts "dev: learnings synced from #{@settings.knowledge_repo} (#{T.must(@cache).dir})."
        out.puts "dev: no enclosing project — skipped the invariants link." if @project_root.nil?
      end

      # `dev learnings status`: the configured repo, cache location/age, and
      # what is rendered and linked.
      #
      # @param out [IO, StringIO]
      # @return [void]
      sig { params(out: T.any(IO, StringIO)).void }
      def status(out:)
        repo = @settings.knowledge_repo
        if repo.nil?
          out.puts "dev: no knowledge repo configured — add `knowledge_repo: <owner>/<repo>` " \
            "to #{@settings.config_path} (or set DEV_KNOWLEDGE_REPO)."
          return
        end

        out.puts "dev: knowledge repo: #{repo}"
        cache = T.must(@cache)
        unless cache.present?
          out.puts "dev: cache: #{cache.dir} (not cloned yet — run `dev learnings sync`)."
          return
        end

        out.puts "dev: cache: #{cache.dir} (refreshed #{format_age(Time.now - T.must(cache.synced_at))} ago)."
        status_org_tier(out)
        status_project_tier(out)
      end

      # @param out [IO, StringIO]
      # @return [void]
      # @raise [InvariantsUnavailableError] when the block cannot be produced
      sig { params(out: T.any(IO, StringIO)).void }
      def invariants(out:)
        cache = @cache
        if cache.nil?
          raise InvariantsUnavailableError,
            "no knowledge repo configured — add `knowledge_repo: <owner>/<repo>` " \
            "to #{@settings.config_path} (or set DEV_KNOWLEDGE_REPO)."
        end
        unless cache.present?
          raise InvariantsUnavailableError,
            "the knowledge repo cache has not been cloned yet — run `dev learnings sync`."
        end

        block = @renderer.prompt_block(cache.index_file)
        raise InvariantsUnavailableError, "#{cache.index_file} has no `## Invariants` section." if block.nil?

        out.puts block
      end

      # Scaffold the canonical learnings layout at the enclosing project's
      # root: the empty repo-tier index, or the org knowledge-repo layout
      # with org: true. The scaffold is write-once-committed — an existing
      # index makes this a reported no-op (exit 0), never an overwrite — so
      # consumers can call init unconditionally before capturing.
      #
      # @param out [IO, StringIO]
      # @param org [Boolean] scaffold the org knowledge-repo layout instead
      #   of the repo tier
      # @return [void]
      # @raise [NoEnclosingProjectError] when run outside any project
      sig { params(out: T.any(IO, StringIO), org: T::Boolean).void }
      def init(out:, org: false)
        project_root = @project_root
        if project_root.nil?
          raise NoEnclosingProjectError,
            "no enclosing project — run `dev learnings init` inside the repo to scaffold."
        end

        if org
          @scaffolder.scaffold_org(project_root)
          out.puts "dev: scaffolded #{Layout.org_index_file(project_root)} and " \
            "#{Layout.org_skills_dir(project_root)}/ (the org knowledge-repo layout) — commit them."
        else
          @scaffolder.scaffold_repo(project_root)
          out.puts "dev: scaffolded #{Layout.repo_index_file(project_root)} " \
            "(this repo's empty always-on learnings index) — commit it."
        end
      rescue Scaffolder::IndexAlreadyExistsError => e
        out.puts "dev: #{e.message}"
      end

      private

      # The org tier's rendered state: the machine-side invariants render.
      #
      # @param out [IO, StringIO]
      # @return [void]
      sig { params(out: T.any(IO, StringIO)).void }
      def status_org_tier(out)
        rendered = @synchronizer.rendered_invariants_file
        out.puts(if rendered.file?
          "dev: invariants: rendered at #{rendered}."
        else
          "dev: invariants: not rendered (no invariants section in the index, or never synced)."
        end)
      end

      # The project tier's linked state: the invariants link, or a pointer
      # when there is no enclosing project.
      #
      # @param out [IO, StringIO]
      # @return [void]
      sig { params(out: T.any(IO, StringIO)).void }
      def status_project_tier(out)
        project_root = @project_root
        if project_root.nil?
          out.puts "dev: project: none — run inside a repo to see its invariants link."
          return
        end

        rules_file = @synchronizer.project_rules_file(project_root)
        out.puts "dev: project invariants link: #{rules_file} (#{invariants_link_state(rules_file)})."
      end

      # @param rules_file [Pathname]
      # @return [String]
      sig { params(rules_file: Pathname).returns(String) }
      def invariants_link_state(rules_file)
        if rules_file.symlink? && rules_file.readlink == @synchronizer.rendered_invariants_file
          "linked"
        elsif rules_file.symlink? || rules_file.file?
          "present but not dev's link — run `dev learnings sync`"
        else
          "missing — run `dev learnings sync`"
        end
      end

      # @param seconds [Float]
      # @return [String] a compact human age, e.g. "42s", "7m", "3h", "2d"
      sig { params(seconds: Float).returns(String) }
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

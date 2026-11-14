# typed: strict
# frozen_string_literal: true

require "pathname"
require "stringio"
require_relative "../footprint"
require_relative "../settings"
require_relative "../ui"
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
    #                  unconditionally before capturing. The repo tier also
    #                  ensures the repo's .gitignore carries dev's managed
    #                  footprint (idempotent; --gitignore does only that)
    #
    # One public method per verb; the `learnings` group in the command tree
    # routes `sync` / `status` / `invariants` / `init` to them, and the
    # leaves own the argv shape (flags, no stray arguments).
    #
    # The verbs speak through the Ui: a frame per verb, a spin
    # for the captured pull, a `{{v}}` / `{{x}}` note per fact with its
    # remedy, the one-line result last. `invariants` is the exception — a
    # payload other tools parse, printed bare on its stream.
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
      # @param ui [Dev::Ui] the terminal the verbs speak through
      # @param settings [Dev::Settings]
      # @param cache [Dev::Learnings::Cache, nil] override for tests; defaults
      #   to a cache over the configured knowledge repo (nil when unconfigured)
      # @param synchronizer [Dev::Learnings::Synchronizer, Dev::Learnings::UnconfiguredSynchronizer, nil]
      # @param renderer [Dev::Learnings::InvariantsRenderer]
      # @param scaffolder [Dev::Learnings::Scaffolder]
      # @param gitignore [Dev::Footprint::Gitignore] writes dev's managed
      #   footprint into the repo's .gitignore
      sig do
        params(
          project_root: T.nilable(T.any(Pathname, String)),
          ui: Dev::Ui,
          settings: Dev::Settings,
          cache: T.nilable(Cache),
          synchronizer: T.untyped,
          renderer: InvariantsRenderer,
          scaffolder: Scaffolder,
          gitignore: Dev::Footprint::Gitignore,
        ).void
      end
      def initialize(project_root:, ui:, settings: Dev::Settings.new, cache: nil, synchronizer: nil,
                     renderer: InvariantsRenderer.new, scaffolder: Scaffolder.new,
                     gitignore: Dev::Footprint::Gitignore.new)
        @project_root = T.let(project_root && Pathname(project_root), T.nilable(Pathname))
        @ui = ui
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
        @gitignore = gitignore
      end

      # `dev learnings sync`: the org tier, blocking, errors bubbling — cache
      # pull, org skills channel, invariants render + project link. The pull
      # is the spin (git, captured); what it distributed are the facts.
      #
      # @return [void]
      # @raise [Synchronizer::KnowledgeRepoNotConfiguredError] no knowledge repo configured
      # @raise [Cache::KnowledgeCloneError] when the initial clone fails
      # @raise [Cache::KnowledgeFetchError] when the refresh fails
      sig { void }
      def sync
        cache = @cache
        # Unconfigured: the null synchronizer's sync! is the refusal, with
        # the configuration instructions — raised before any frame opens.
        return @synchronizer.sync!(project_root: @project_root) if cache.nil?

        repo = T.must(@settings.knowledge_repo)
        project_root = @project_root
        @ui.frame("Syncing the org learnings from #{repo}") do
          @ui.spin("Pulling #{repo} into #{cache.dir} and distributing it") { @synchronizer.sync!(project_root: project_root) }
          @ui.note("{{v}} invariants rendered at #{@synchronizer.rendered_invariants_file}")
          if project_root
            @ui.note("{{v}} invariants linked at #{@synchronizer.project_rules_file(project_root)}")
          else
            @ui.note("no enclosing project — skipped the invariants link.")
          end
          @ui.note("{{v}} learnings synced from #{repo} (#{cache.dir}).")
        end
      end

      # `dev learnings status`: the configured repo, cache location/age, and
      # what is rendered and linked — a frame for the org tier, one for the
      # project, a `{{v}}` / `{{x}}` fact per line with its remedy.
      #
      # @return [void]
      sig { void }
      def status
        repo = @settings.knowledge_repo
        if repo.nil?
          @ui.note("no knowledge repo configured — add `knowledge_repo: <owner>/<repo>` " \
            "to #{@settings.config_path} (or set DEV_KNOWLEDGE_REPO).")
          return
        end

        cache = T.must(@cache)
        @ui.frame("Org learnings (#{repo})") do
          if cache.present?
            @ui.note("{{v}} cache: #{cache.dir} (refreshed #{format_age(Time.now - T.must(cache.synced_at))} ago).")
            status_org_tier
          else
            @ui.note("{{x}} cache: #{cache.dir} (not cloned yet — run `dev learnings sync`).")
          end
        end
        status_project_tier if cache.present?
      end

      # `dev learnings invariants`: the Tier-0 prompt block, bare — a payload
      # consumers (ai-flow) parse, never the Ui's.
      #
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
      # consumers can call init unconditionally before capturing. The repo
      # tier then ensures the repo's .gitignore carries dev's managed
      # footprint — per path, so re-running is a no-op and a user's own
      # patterns are respected; `gitignore_only` skips the index for a repo
      # that is already scaffolded.
      #
      # @param org [Boolean] scaffold the org knowledge-repo layout instead
      #   of the repo tier
      # @param gitignore_only [Boolean] only ensure the .gitignore footprint
      # @return [void]
      # @raise [NoEnclosingProjectError] when run outside any project
      sig { params(org: T::Boolean, gitignore_only: T::Boolean).void }
      def init(org: false, gitignore_only: false)
        project_root = @project_root
        if project_root.nil?
          raise NoEnclosingProjectError,
            "no enclosing project — run `dev learnings init` inside the repo to scaffold."
        end

        if org
          @ui.frame("Org knowledge-repo scaffold (#{project_root})") do
            @scaffolder.scaffold_org(project_root)
            @ui.note("{{v}} scaffolded #{Layout.org_index_file(project_root)} and " \
              "#{Layout.org_skills_dir(project_root)}/ (the org knowledge-repo layout) — commit them.")
          end
          return
        end

        @ui.frame("Learnings scaffold (#{project_root})") do
          scaffold_repo_index(project_root) unless gitignore_only
          ensure_gitignore(project_root)
        end
      end

      private

      # The write-once index: scaffolded, or reported as already there (the
      # scaffolder's refusal is the no-op's wording, not a failure).
      #
      # @param project_root [Pathname]
      # @return [void]
      sig { params(project_root: Pathname).void }
      def scaffold_repo_index(project_root)
        @scaffolder.scaffold_repo(project_root)
        @ui.note("{{v}} scaffolded #{Layout.repo_index_file(project_root)} " \
          "(this repo's empty always-on learnings index) — commit it.")
      rescue Scaffolder::IndexAlreadyExistsError => e
        @ui.note(e.message)
      end

      # @param project_root [Pathname]
      # @return [void]
      sig { params(project_root: Pathname).void }
      def ensure_gitignore(project_root)
        added = @gitignore.apply(project_root)
        @ui.note(if added.empty?
          "{{v}} .gitignore already covers dev's managed footprint."
        else
          "{{v}} added #{added.join(", ")} to .gitignore (dev's managed footprint) — commit it."
        end)
      end

      # The org tier's rendered state: the machine-side invariants render.
      #
      # @return [void]
      sig { void }
      def status_org_tier
        rendered = @synchronizer.rendered_invariants_file
        @ui.note(if rendered.file?
          "{{v}} invariants: rendered at #{rendered}."
        else
          "{{x}} invariants: not rendered (no invariants section in the index, or never synced)."
        end)
      end

      # The project tier's linked state: a frame for the project with the
      # invariants link and its footprint, or a pointer when there is no
      # enclosing project.
      #
      # @return [void]
      sig { void }
      def status_project_tier
        project_root = @project_root
        if project_root.nil?
          @ui.note("project: none — run inside a repo to see its invariants link.")
          return
        end

        @ui.frame("Project (#{project_root})") do
          @ui.note(invariants_link_fact(@synchronizer.project_rules_file(project_root)))
          Dev::Footprint.warn_missing(@ui, project_root, [Layout::GITIGNORE_FOOTPRINT])
        end
      end

      # @param rules_file [Pathname] the project's invariants rules file
      # @return [String] the link fact with its glyph: linked, or how it is
      #   not and the remedy
      sig { params(rules_file: Pathname).returns(String) }
      def invariants_link_fact(rules_file)
        if rules_file.symlink? && rules_file.readlink == @synchronizer.rendered_invariants_file
          "{{v}} invariants link: #{rules_file} (linked)."
        elsif rules_file.symlink? || rules_file.file?
          "{{x}} invariants link: #{rules_file} (present but not dev's link — run `dev learnings sync`)."
        else
          "{{x}} invariants link: #{rules_file} (missing — run `dev learnings sync`)."
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

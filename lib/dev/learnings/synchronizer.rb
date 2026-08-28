# typed: strict
# frozen_string_literal: true

require "pathname"
require "sorbet-runtime"
require_relative "../settings"
require_relative "../skill_installer"
require_relative "cache"
require_relative "invariants_renderer"

module Dev
  module Learnings
    # Orchestrates the org tier of the learnings read path: refresh the
    # machine cache of the knowledge repo (bounded-inline on hooks, blocking
    # for `dev learnings sync`), link the cache's skills user-globally into
    # ~/.cursor/skills, render the invariants index once beside the cache, and
    # link the render into the project at hand. The refresh always precedes
    # distribution, so a hook never renders content it just found stale.
    #
    # Construct through Synchronizer.for: unconfigured machines (no
    # `knowledge_repo` setting) get an UnconfiguredSynchronizer null object —
    # dev is public and ships only the mechanism; content stays in the
    # private knowledge repo. The constructor itself requires a cache, so a
    # real Synchronizer is never in a half-configured state.
    class Synchronizer
      extend T::Sig

      # `dev learnings sync` was asked to sync with no knowledge repo configured.
      class KnowledgeRepoNotConfiguredError < RuntimeError; end

      # Where the per-project link to the machine-side render lands. Committed
      # footprint per repo is one .gitignore line for this path.
      ORG_INVARIANTS_RULE_SUBDIRS = [".cursor", "rules", "org-invariants.mdc"].freeze

      # The machine-side render, beside the cache clone (one refresh updates
      # every project on the machine through its symlink).
      RENDERED_INVARIANTS_FILENAME = "org-invariants.mdc"

      class << self
        extend T::Sig

        # The one construction path callers use: the real synchronizer over
        # the configured knowledge repo's cache, or the unconfigured null
        # object when no repo is set.
        #
        # @param settings [Dev::Settings]
        # @param skill_installer [Dev::SkillInstaller]
        # @param renderer [Dev::Learnings::InvariantsRenderer]
        # @return [Synchronizer, UnconfiguredSynchronizer]
        sig do
          params(
            settings: Dev::Settings,
            skill_installer: Dev::SkillInstaller,
            renderer: InvariantsRenderer,
          ).returns(T.any(Synchronizer, UnconfiguredSynchronizer))
        end
        def for(settings: Dev::Settings.new, skill_installer: Dev::SkillInstaller.new,
                renderer: InvariantsRenderer.new)
          repo = settings.knowledge_repo
          return UnconfiguredSynchronizer.new(settings: settings) if repo.nil?

          new(settings: settings, cache: Cache.new(repo: repo), skill_installer: skill_installer, renderer: renderer)
        end
      end

      # @param settings [Dev::Settings]
      # @param cache [Dev::Learnings::Cache] the knowledge repo's machine
      #   cache — required; unconfigured machines go through .for instead
      # @param skill_installer [Dev::SkillInstaller] target for the org skill
      #   links; defaults to the user-global ~/.cursor/skills
      # @param renderer [Dev::Learnings::InvariantsRenderer]
      sig do
        params(
          cache: Cache,
          settings: Dev::Settings,
          skill_installer: Dev::SkillInstaller,
          renderer: InvariantsRenderer,
        ).void
      end
      def initialize(cache:, settings: Dev::Settings.new, skill_installer: Dev::SkillInstaller.new,
                     renderer: InvariantsRenderer.new)
        @settings = settings
        @cache = cache
        @skill_installer = skill_installer
        @renderer = renderer
      end

      # @return [Pathname] the machine-side invariants render (beside the cache)
      sig { returns(Pathname) }
      def rendered_invariants_file
        @cache.dir.dirname / RENDERED_INVARIANTS_FILENAME
      end

      # @param project_root [Pathname, String] the enclosing project
      # @return [Pathname] the project's link to the invariants render
      sig { params(project_root: T.any(Pathname, String)).returns(Pathname) }
      def project_rules_file(project_root)
        Pathname(project_root).join(*ORG_INVARIANTS_RULE_SUBDIRS)
      end

      # The passive hook entry (`dev up` / `install-deps` / `dev plan`): pull
      # inline within the cache's short timeout (falling back to the current
      # cache when the network is slower, or offline), then distribute.
      # Never raises: learnings sync is hygiene riding another command, and
      # hygiene must not block correctness.
      #
      # @param project_root [Pathname, String, nil] project to link the
      #   invariants render into; nil skips the link (no project context)
      # @return [void]
      sig { params(project_root: T.nilable(T.any(Pathname, String))).void }
      def sync(project_root: nil)
        @cache.refresh_bounded
        distribute(project_root)
      rescue StandardError => e
        $stderr.puts "dev: warning: org learnings sync failed (#{e.message})."
      end

      # The explicit entry (`dev learnings sync`): refresh now, blocking, then
      # distribute. Errors bubble — the user asked for this sync and must hear
      # when it fails.
      #
      # @param project_root [Pathname, String, nil] as for sync
      # @return [void]
      # @raise [Cache::KnowledgeCloneError] when the initial clone fails
      # @raise [Cache::KnowledgeFetchError] when the refresh fails
      sig { params(project_root: T.nilable(T.any(Pathname, String))).void }
      def sync!(project_root: nil)
        @cache.refresh
        distribute(project_root)
      end

      private

      # Link the cached skills corpus user-globally, refresh the machine-side
      # invariants render, and point the project's rules file at it. A no-op
      # before the first clone lands.
      #
      # @param project_root [Pathname, String, nil]
      # @return [void]
      sig { params(project_root: T.nilable(T.any(Pathname, String))).void }
      def distribute(project_root)
        return unless @cache.present?

        @skill_installer.install_all(@cache.skills_dir)
        @renderer.render(
          index_file: @cache.index_file,
          rendered_file: rendered_invariants_file,
          repo: T.must(@settings.knowledge_repo),
        )
        return unless project_root

        @renderer.link(rendered_file: rendered_invariants_file, rules_file: project_rules_file(project_root))
      end
    end

    # The null synchronizer for machines without a `knowledge_repo` setting
    # (Synchronizer.for hands it out). The passive hook is a silent no-op —
    # no org sync is a supported state, not an error — while the explicit
    # `dev learnings sync` raises with configuration instructions.
    class UnconfiguredSynchronizer
      extend T::Sig

      # @param settings [Dev::Settings] used only to point the error message
      #   at the right config file
      sig { params(settings: Dev::Settings).void }
      def initialize(settings: Dev::Settings.new)
        @settings = settings
      end

      # The passive hook entry: nothing to sync, nothing to say.
      #
      # @param project_root [Pathname, String, nil] unused; matches
      #   Synchronizer#sync
      # @return [void]
      sig { params(project_root: T.nilable(T.any(Pathname, String))).void }
      def sync(project_root: nil); end

      # The explicit entry: the user asked for a sync that cannot happen.
      #
      # @param project_root [Pathname, String, nil] unused; matches
      #   Synchronizer#sync!
      # @return [void]
      # @raise [Synchronizer::KnowledgeRepoNotConfiguredError] always
      sig { params(project_root: T.nilable(T.any(Pathname, String))).void }
      def sync!(project_root: nil)
        raise Synchronizer::KnowledgeRepoNotConfiguredError,
          "no knowledge repo configured — add `knowledge_repo: <owner>/<repo>` " \
          "to #{@settings.config_path} (or set DEV_KNOWLEDGE_REPO)."
      end
    end
  end
end

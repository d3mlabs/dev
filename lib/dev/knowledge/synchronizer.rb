# frozen_string_literal: true

require "pathname"
require_relative "../settings"
require_relative "../skill_installer"
require_relative "cache"
require_relative "invariants_renderer"

module Dev
  module Knowledge
    # Orchestrates org knowledge distribution: refresh the machine cache
    # (TTL-gated and async on hooks, forced and blocking for `dev knowledge
    # sync`), link the cache's skills user-globally into ~/.cursor/skills,
    # and render the invariants index into the project at hand.
    #
    # Unconfigured machines (no `knowledge_repo` setting) have no org sync —
    # dev is public and ships only the mechanism; content stays in the
    # private knowledge repo.
    class Synchronizer
      # `dev knowledge sync` was asked to sync with no knowledge repo configured.
      class KnowledgeRepoNotConfiguredError < RuntimeError; end

      # Where the generated always-on rule lands inside a project. Committed
      # footprint per repo is one .gitignore line for this path.
      ORG_INVARIANTS_RULE_SUBDIRS = [".cursor", "rules", "org-invariants.mdc"].freeze

      # @param settings [Dev::Settings]
      # @param cache [Dev::Knowledge::Cache, nil] override for tests; defaults
      #   to a cache over the configured knowledge repo (nil when unconfigured)
      # @param skill_installer [Dev::SkillInstaller] target for the org skill
      #   links; defaults to the user-global ~/.cursor/skills
      # @param renderer [Dev::Knowledge::InvariantsRenderer]
      def initialize(settings: Dev::Settings.new, cache: nil, skill_installer: Dev::SkillInstaller.new,
                     renderer: InvariantsRenderer.new)
        @settings = settings
        repo = settings.knowledge_repo
        @cache = cache || (repo && Cache.new(repo: repo))
        @skill_installer = skill_installer
        @renderer = renderer
      end

      # @return [Boolean] whether a knowledge repo is configured
      def configured?
        !@cache.nil?
      end

      # The passive hook entry (`dev up` / `install-deps` / `dev plan`): kick
      # an async refresh when the TTL lapsed, then distribute whatever the
      # cache currently holds — idempotent, content-compared, and never
      # blocking on the network. Never raises: knowledge sync is hygiene
      # riding another command, and hygiene must not block correctness.
      #
      # @param project_root [Pathname, String, nil] project to render the
      #   invariants rule into; nil skips the render (no project context)
      # @return [void]
      def sync(project_root: nil)
        return unless configured?

        @cache.refresh_async if @cache.stale?(@settings.knowledge_ttl)
        distribute(project_root)
      rescue StandardError => e
        $stderr.puts "dev: warning: org knowledge sync failed (#{e.message})."
      end

      # The explicit entry (`dev knowledge sync`): refresh now, blocking and
      # TTL-bypassed, then distribute. Errors bubble — the user asked for
      # this sync and must hear when it fails.
      #
      # @param project_root [Pathname, String, nil] as for sync
      # @return [void]
      # @raise [KnowledgeRepoNotConfiguredError] when no repo is configured
      # @raise [Cache::KnowledgeCloneError] when the initial clone fails
      # @raise [Cache::KnowledgeFetchError] when the refresh fails
      def sync!(project_root: nil)
        unless configured?
          raise KnowledgeRepoNotConfiguredError,
            "no knowledge repo configured — add `knowledge_repo: <owner>/<repo>` " \
            "to #{@settings.config_path} (or set DEV_KNOWLEDGE_REPO)."
        end

        @cache.refresh
        distribute(project_root)
      end

      private

      # Link the cached skills corpus user-globally and render the invariants
      # rule into the project. A no-op before the first clone lands.
      #
      # @param project_root [Pathname, String, nil]
      # @return [void]
      def distribute(project_root)
        return unless @cache.present?

        @skill_installer.install_all(@cache.skills_dir)
        return unless project_root

        @renderer.render(
          index_file: @cache.index_file,
          rules_file: Pathname(project_root).join(*ORG_INVARIANTS_RULE_SUBDIRS),
          repo: @settings.knowledge_repo,
        )
      end
    end
  end
end

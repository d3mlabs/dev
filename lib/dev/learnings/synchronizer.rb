# frozen_string_literal: true

require "pathname"
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
    # Unconfigured machines (no `knowledge_repo` setting) have no org sync —
    # dev is public and ships only the mechanism; content stays in the
    # private knowledge repo.
    class Synchronizer
      # `dev learnings sync` was asked to sync with no knowledge repo configured.
      class KnowledgeRepoNotConfiguredError < RuntimeError; end

      # Where the per-project link to the machine-side render lands. Committed
      # footprint per repo is one .gitignore line for this path.
      ORG_INVARIANTS_RULE_SUBDIRS = [".cursor", "rules", "org-invariants.mdc"].freeze

      # The machine-side render, beside the cache clone (one refresh updates
      # every project on the machine through its symlink).
      RENDERED_INVARIANTS_FILENAME = "org-invariants.mdc"

      # @param settings [Dev::Settings]
      # @param cache [Dev::Learnings::Cache, nil] override for tests; defaults
      #   to a cache over the configured knowledge repo (nil when unconfigured)
      # @param skill_installer [Dev::SkillInstaller] target for the org skill
      #   links; defaults to the user-global ~/.cursor/skills
      # @param renderer [Dev::Learnings::InvariantsRenderer]
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

      # @return [Pathname] the machine-side invariants render (beside the cache)
      def rendered_invariants_file
        @cache.dir.dirname / RENDERED_INVARIANTS_FILENAME
      end

      # @param project_root [Pathname, String] the enclosing project
      # @return [Pathname] the project's link to the invariants render
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
      def sync(project_root: nil)
        return unless configured?

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

      # Link the cached skills corpus user-globally, refresh the machine-side
      # invariants render, and point the project's rules file at it. A no-op
      # before the first clone lands.
      #
      # @param project_root [Pathname, String, nil]
      # @return [void]
      def distribute(project_root)
        return unless @cache.present?

        @skill_installer.install_all(@cache.skills_dir)
        @renderer.render(
          index_file: @cache.index_file,
          rendered_file: rendered_invariants_file,
          repo: @settings.knowledge_repo,
        )
        return unless project_root

        @renderer.link(rendered_file: rendered_invariants_file, rules_file: project_rules_file(project_root))
      end
    end
  end
end

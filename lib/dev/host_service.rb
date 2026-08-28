# frozen_string_literal: true

require "open3"
require "pathname"
require_relative "cd/hook_installer"
require_relative "learnings/synchronizer"
require_relative "settings"
require_relative "skill_installer"

module Dev
  # What keeping a host converged consists of — one method per piece of
  # machine state dev owns: the brew tooling layer, the shell RC hook, the
  # user-global skill links, and the org learnings artifacts. Every
  # operation shares the same contract: no user arguments, idempotent, and
  # warn-only (host hygiene rides other commands and must never block
  # them). Commands compose these verbs — `dev up`'s host half is
  # converge_tooling + install_rc_hook; `dev plan` and `install-deps`
  # refresh the cheap artifact pair on every invocation.
  #
  # Anything host-scoped but not convergence-shaped (a user-facing verb
  # with arguments, a reporting surface) is not this class's business —
  # it belongs to its own command accessor.
  class HostService
    # A canonical brew formula token: bare name or fully tap-qualified
    # user/repo/name (exactly one or three segments — a two-segment form is
    # not a formula reference), lowercase throughout (brew stores taps
    # downcased, so the canonical spelling is the lowercase one). The
    # deployment_formula value crosses a settings boundary into a brew
    # invocation, so validate its shape — a leading `-` must never reach
    # brew as a flag.
    FORMULA_PATTERN =
      %r{\A[a-z0-9][a-z0-9_.+@-]*(?:/[a-z0-9][a-z0-9_.+@-]*/[a-z0-9][a-z0-9_.+@-]*)?\z}

    # The generic tool's own formula — the self-update target for tapless
    # individuals who installed dev-core directly (no deployment).
    CORE_FORMULA = "dev-core"

    # Runs brew commands. Split by what the caller needs: `run` streams
    # output to the terminal (installs the user should see), `quiet?` only
    # answers success (existence checks).
    class BrewExecutor
      # @param cmd [Array<String>] argv, never a shell string
      # @return [Boolean]
      def run(*cmd)
        !!system(*cmd)
      end

      # @param cmd [Array<String>] argv, never a shell string
      # @return [Boolean]
      def quiet?(*cmd)
        _out, _err, status = Open3.capture3(*cmd)
        status.success?
      rescue SystemCallError
        false
      end
    end

    # @param settings [Dev::Settings] source of deployment_formula and the
    #   system config location (whose directory also holds the Brewfile)
    # @param brew_executor [#run, #quiet?] brew invocation seam, injectable
    #   so tests never call brew
    # @param hook_installer [Dev::Cd::HookInstaller] the shell RC hook seam
    # @param skill_installer [Dev::SkillInstaller] target for dev's shipped
    #   skill links (defaults to the user-global ~/.cursor/skills)
    # @param synchronizer [Dev::Learnings::Synchronizer, Dev::Learnings::UnconfiguredSynchronizer]
    #   the org learnings read path (the unconfigured null object when no
    #   knowledge repo is set)
    def initialize(settings: Dev::Settings.new, brew_executor: BrewExecutor.new,
                   hook_installer: Dev::Cd::HookInstaller.new,
                   skill_installer: Dev::SkillInstaller.new,
                   synchronizer: Dev::Learnings::Synchronizer.for(settings: settings))
      @settings = settings
      @brew_executor = brew_executor
      @hook_installer = hook_installer
      @skill_installer = skill_installer
      @synchronizer = synchronizer
    end

    # The brew tooling layer (plans#26): brew converges brew — dev never
    # re-implements host tooling convergence, it only *triggers* brew's,
    # the same way it triggers bundler for gems. In order: deployment
    # sanity warning, `brew update` (so a deployment fix propagates on the
    # very next `dev up`), a scoped `brew upgrade` of the org's
    # self-named deployment formula (whose revision delivers dev itself
    # plus the org's config.yml and Brewfile into the prefix's etc/dev/),
    # then `brew bundle install` against the etc/dev/Brewfile when one
    # exists — the org's tooling list beyond the tool's own dependencies.
    #
    # dev owns no throttle: measured no-op costs are sub-second per step
    # (update ~0.5s, scoped upgrade ~0.4s, bundle ~0.9s), and brew's own
    # HOMEBREW_AUTO_UPDATE_SECS remains the only network rate limiter —
    # tunable through brew, not dev. The Brewfile presence is convention,
    # not configuration: no file (tapless individual, CI) means the step
    # self-skips. A no-op on brewless machines (no prefix means no system
    # config location, no Brewfile, nothing to upgrade).
    #
    # @return [void]
    def converge_tooling
      return unless system_config_path

      warn_unnamed_deployment
      self_update
      converge_brewfile if brewfile_path.file?
    end

    # Ensure the `dev cd` wrapper function + completer are in the user's
    # shell RC (idempotent) — provisioning is where dev's RC hooks land,
    # next to the shadowenv one.
    #
    # @return [Symbol, false] :added, :already_present, or false
    #   (unsupported shell)
    def install_rc_hook
      @hook_installer.ensure_installed
    end

    # Install or refresh the user-global links to dev's own shipped skills.
    # Cheap and idempotent, so every hook point can afford it — and `brew
    # upgrade` refreshes shipped skills automatically (the symlinks resolve
    # through the installed tree, wherever brew put it).
    #
    # @return [void]
    def install_skills
      @skill_installer.install_all(Dev::SkillInstaller::SHIPPED_SKILLS_DIR)
    end

    # Refresh the machine's org learnings artifacts, best-effort (the
    # network pull bounded by a short timeout, never raising). The blocking
    # error-bubbling variant stays `dev learnings sync`'s own business.
    #
    # @param project_root [Pathname, String, nil] project to link the
    #   invariants render into; nil skips the link (no project context)
    # @return [void]
    def sync_learnings(project_root: nil)
      @synchronizer.sync(project_root: project_root)
    end

    private

    # An etc config.yml is evidence of a deployment, and a deployment must
    # name itself or org updates silently stop flowing (self-update has no
    # target). Resolved-value check: a user-file or ENV override counts as
    # named. Hand-rollers with only a Brewfile in etc never see this.
    #
    # @return [void]
    def warn_unnamed_deployment
      return unless File.exist?(system_config_path.to_s)
      return if @settings.deployment_formula

      $stderr.puts "dev: warning: a deployment config exists at #{system_config_path} but no " \
        "deployment_formula is set — dev cannot self-update. Fix with: " \
        "`dev config set deployment_formula <org>/<tap>/<formula>`."
    end

    # `brew update` then a scoped upgrade of exactly one formula — never a
    # blanket `brew upgrade`; the user's unrelated packages are not dev's
    # business.
    #
    # @return [void]
    def self_update
      unless @brew_executor.run("brew", "update", "--quiet")
        $stderr.puts "dev: warning: brew update failed — skipping the dev self-update check."
        return
      end

      target = upgrade_target
      if target && !@brew_executor.run("brew", "upgrade", "--quiet", target)
        $stderr.puts "dev: warning: brew upgrade #{target} failed."
      end
    end

    # The one formula the self-update may touch: the org's self-named
    # deployment, or dev-core for tapless individuals, or nothing (source
    # checkouts).
    #
    # @return [String, nil]
    def upgrade_target
      formula = @settings.deployment_formula
      if formula
        return formula if FORMULA_PATTERN.match?(formula)

        $stderr.puts "dev: warning: ignoring malformed deployment_formula #{formula.inspect}."
        return nil
      end

      CORE_FORMULA if @brew_executor.quiet?("brew", "list", "--formula", "--versions", CORE_FORMULA)
    end

    # The org tooling list, converged by brew's own mechanism. brew bundle
    # upgrades outdated entries by default, so org tools stay current.
    #
    # @return [void]
    def converge_brewfile
      return if @brew_executor.run("brew", "bundle", "install", "--file=#{brewfile_path}")

      $stderr.puts "dev: warning: brew bundle failed for #{brewfile_path} — host tooling may be incomplete."
    end

    # The org Brewfile lives beside the system config.yml — both are the
    # deployment formula's payload into the prefix's etc/dev/.
    #
    # @return [Pathname]
    def brewfile_path
      Pathname(system_config_path.to_s).dirname / "Brewfile"
    end

    # @return [String, nil] nil on brewless machines (empty layer)
    def system_config_path
      @settings.system_config_path
    end
  end
end

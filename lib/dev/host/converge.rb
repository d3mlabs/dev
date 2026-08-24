# frozen_string_literal: true

require "open3"
require "pathname"
require_relative "../settings"

module Dev
  module Host
    # The host layer of `dev up` (plans#26): brew converges brew — dev never
    # re-implements host tooling convergence, it only *triggers* brew's, the
    # same way it triggers bundler for gems. Three steps, all brew-executed:
    #
    #   1. `brew update`, so a deployment fix propagates on the very next
    #      `dev up`
    #   2. scoped `brew upgrade` of the org's deployment formula — the
    #      deployment names itself via the `deployment_formula` setting; the
    #      formula revision delivers dev itself plus the org's config.yml and
    #      Brewfile into the prefix's etc/dev/
    #   3. `brew bundle install` against the etc/dev/Brewfile when one exists
    #      — the org's tooling list beyond the tool's own dependencies
    #
    # dev owns no throttle: measured no-op costs are sub-second per step
    # (update ~0.5s, scoped upgrade ~0.4s, bundle ~0.9s), and brew's own
    # HOMEBREW_AUTO_UPDATE_SECS remains the only network rate limiter —
    # tunable through brew, not dev.
    #
    # The Brewfile presence is convention, not configuration: no file (tapless
    # individual, CI) means the step self-skips. The whole layer is warn-only:
    # a failed self-update or tooling converge never blocks project
    # provisioning (offline `dev up` still works).
    class Converge
      # A brew formula token: bare name or tap-qualified org/repo/name. The
      # deployment_formula value crosses a settings boundary into a brew
      # invocation, so validate its shape — a leading `-` must never reach
      # brew as a flag.
      FORMULA_PATTERN = %r{\A[A-Za-z0-9][\w.+@-]*(?:/[A-Za-z0-9][\w.-]*){0,2}\z}

      # The generic tool's own formula — the self-update target for tapless
      # individuals who installed dev-core directly (no deployment).
      CORE_FORMULA = "dev-core"

      # Runs brew commands. Split by what the caller needs: `run` streams
      # output to the terminal (installs the user should see), `quiet?` only
      # answers success (existence checks).
      class Executor
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
      # @param executor [#run, #quiet?] brew invocation seam, injectable so
      #   tests never call brew
      def initialize(settings: Dev::Settings.new, executor: Executor.new)
        @settings = settings
        @executor = executor
      end

      # The whole host layer, in order: deployment sanity warning,
      # self-update, Brewfile converge. A no-op on brewless machines (no
      # prefix means no system config location, no Brewfile, nothing to
      # upgrade).
      #
      # @return [void]
      def run
        return unless system_config_path

        warn_unnamed_deployment
        self_update
        converge_brewfile if brewfile_path.file?
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
        unless @executor.run("brew", "update", "--quiet")
          $stderr.puts "dev: warning: brew update failed — skipping the dev self-update check."
          return
        end

        target = upgrade_target
        if target && !@executor.run("brew", "upgrade", "--quiet", target)
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

        CORE_FORMULA if @executor.quiet?("brew", "list", "--formula", "--versions", CORE_FORMULA)
      end

      # The org tooling list, converged by brew's own mechanism. brew bundle
      # upgrades outdated entries by default, so org tools stay current.
      #
      # @return [void]
      def converge_brewfile
        return if @executor.run("brew", "bundle", "install", "--file=#{brewfile_path}")

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
end

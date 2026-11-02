# typed: strict
# frozen_string_literal: true

require "stringio"

require "dev/settings"

module Dev
  # Have a host identity trust the deployment's tap. Homebrew 7 loads no
  # formula from a third-party tap its *user* has not trusted, and trust is
  # per user (`~/.homebrew/trust.json`), so the operator's does not carry
  # over to the other identities a host runs brew as: the Linux runner user
  # (dev#310 — the first `brew upgrade` of dev in a job was refused the
  # formula) and the macOS agent user (dev#374 — a `/build` pass ran
  # `brew trust` itself, a per-user host mutation mid-run, before `dev deps`
  # would resolve a tap-sourced pin). One step, called by both bootstraps
  # (RunnerUser, AgentBootstrap); each hands it the way it runs a command
  # as its user, which is the only thing that differs between them.
  #
  # Idempotent — trusting a trusted tap changes nothing. A brew too old for
  # `trust` has no gate to pass, so its refusal is a warning naming the
  # by-hand command, not a stop.
  class TapTrust
    extend T::Sig

    # Runs argv as the user whose trust is converged and answers whether it
    # exited 0. Output streams: brew's own refusal reaches the terminal
    # ahead of the warning, and a sudo prompt reaches it at all.
    RunAsUser = T.type_alias { T.proc.params(argv: T::Array[String]).returns(T::Boolean) }

    class << self
      extend T::Sig

      # The tap a deployment formula lives in: `user/repo` of a
      # tap-qualified `user/repo/name`; nil for a bare name (dev-core, no
      # tap to trust) or no deployment at all.
      #
      # @param formula [String, nil] Settings#deployment_formula
      # @return [String, nil]
      sig { params(formula: T.nilable(String)).returns(T.nilable(String)) }
      def deployment_tap(formula: Settings.new.deployment_formula)
        parts = formula.to_s.split("/")
        parts.size == 3 ? parts.first(2).join("/") : nil
      end
    end

    # @param user [String] the identity whose trust is converged
    # @param run_as_user [Proc] how to run a command as that user
    # @param brew [String, nil] Homebrew's binary on this host, if any
    # @param tap [String, nil] the deployment's tap; nil for none to trust
    # @param out [IO, StringIO]
    sig do
      params(
        user: String,
        run_as_user: RunAsUser,
        brew: T.nilable(String),
        tap: T.nilable(String),
        out: T.any(IO, StringIO),
      ).void
    end
    def initialize(user:, run_as_user:, brew:, tap: TapTrust.deployment_tap, out: $stdout)
      @user = user
      @run_as_user = run_as_user
      @brew = brew
      @tap = tap
      @out = out
    end

    # Have the user trust the tap, announced; nothing without a tap or
    # without brew. The brew dev found is the one invoked, by path, so the
    # trust lands for the brew the user's `dev deps` will run.
    #
    # @return [void]
    sig { void }
    def trust!
      tap = @tap
      brew = @brew
      return unless tap && brew

      @out.puts ">>> Trusting the tap #{tap} for #{@user} (brew loads nothing from a tap its user has not trusted)"
      return if @run_as_user.call([brew, "trust", "--tap", tap])

      @out.puts "dev: warning: could not trust the tap #{tap} for #{@user} (brew's refusal is above; a brew without " \
                "`trust` has no gate to pass) — if brew as #{@user} is refused the tap's formulae: " \
                "`sudo -iu #{@user} brew trust --tap #{tap}`"
    end
  end
end

# typed: strict
# frozen_string_literal: true

require "dev/settings"
require "dev/ui"

module Dev
  # Have a host identity trust the deployment's tap. Homebrew 7 loads no
  # formula from a third-party tap its *user* has not trusted, and trust is
  # per user (`~/.homebrew/trust.json`), so the operator's does not carry
  # over to the other identities a host runs brew as: the Linux runner user
  # (the first `brew upgrade` of dev in a job was refused the
  # formula) and the macOS agent user (a `/build` pass ran
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

    # A Homebrew tap, `user/repo` — the unit brew's per-user trust is
    # granted to. Built once at the settings boundary (deployment_tap) so
    # nothing downstream re-splits a formula string.
    class Tap < T::Struct
      extend T::Sig

      const :user, String
      const :repo, String

      # The spelling brew takes after `--tap`.
      #
      # @return [String]
      sig { returns(String) }
      def to_s
        "#{user}/#{repo}"
      end
    end

    # A tap-qualified formula name: `user/repo/name`, three non-empty
    # slash-free segments. A bare name (dev-core) has no tap to trust.
    QUALIFIED_FORMULA = T.let(%r{\A([^/]+)/([^/]+)/[^/]+\z}, Regexp)

    # Environment the trust command runs under. `brew trust` writes a
    # per-user file and needs no API data, but brew's implicit auto-update
    # takes a download lock under the prefix — owned by the operator, not
    # the identity trusting here — and fails the whole command on it
    # ("Already trusted tap", then a lock error, then dev's false
    # warning). Same rule as every other brew read dev spawns.
    TRUST_ENV = T.let(%w[HOMEBREW_NO_AUTO_UPDATE=1].freeze, T::Array[String])

    class << self
      extend T::Sig

      # The tap a deployment formula lives in; nil for a bare name or no
      # deployment at all.
      #
      # @param formula [String, nil] Settings#deployment_formula
      # @return [Tap, nil]
      sig { params(formula: T.nilable(String)).returns(T.nilable(Tap)) }
      def deployment_tap(formula: Settings.new.deployment_formula)
        qualified = QUALIFIED_FORMULA.match(formula.to_s)
        return nil unless qualified

        Tap.new(user: T.must(qualified[1]), repo: T.must(qualified[2]))
      end
    end

    # @param user [String] the identity whose trust is converged
    # @param run_as_user [Proc] how to run a command as that user
    # @param brew [String, nil] Homebrew's binary on this host, if any
    # @param tap [Tap, nil] the deployment's tap; nil for none to trust
    # @param ui [Ui] the trust is one step on it (brew streams); a refusal
    #   marks the step and is noted after it
    sig do
      params(
        user: String,
        run_as_user: RunAsUser,
        brew: T.nilable(String),
        tap: T.nilable(Tap),
        ui: Ui,
      ).void
    end
    def initialize(user:, run_as_user:, brew:, tap: TapTrust.deployment_tap, ui: NoUi.new)
      @user = user
      @run_as_user = run_as_user
      @brew = brew
      @tap = tap
      @ui = ui
    end

    # brew refused `trust` (a brew without the command, or its own
    # refusal — printed above by brew itself). Raised inside the step so
    # the step is marked failed, caught right outside: a warning, not a stop.
    class TrustRefusedError < RuntimeError; end

    # Have the user trust the tap, announced; nothing without a tap or
    # without brew. The brew dev found is the one invoked, by path, so the
    # trust lands for the brew the user's `dev deps` will run. The argv
    # carries TRUST_ENV itself (via `env`) so both bootstraps' seams get it
    # without each knowing why.
    #
    # @return [void]
    sig { void }
    def trust!
      tap = @tap
      brew = @brew
      return unless tap && brew

      @ui.step("Trusting the tap #{tap} for #{@user} (brew loads nothing from a tap its user has not trusted)") do
        raise TrustRefusedError, tap.to_s unless @run_as_user.call(["env", *TRUST_ENV, brew, "trust", "--tap", tap.to_s])
      end
    rescue TrustRefusedError
      @ui.note("{{x}} could not trust the tap #{tap} for #{@user} (brew's refusal is above; a brew without " \
               "`trust` has no gate to pass) — if brew as #{@user} is refused the tap's formulae: " \
               "`sudo -iu #{@user} brew trust --tap #{tap}`")
    end
  end
end

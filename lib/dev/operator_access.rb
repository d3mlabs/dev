# typed: strict
# frozen_string_literal: true

require "dev/runner_registry"
require "dev/ui"

module Dev
  # What the operator's own gh login must be able to do before `dev runner
  # register` changes anything on the host. Register checks the
  # runner user's side carefully — its gh login, what it can read of the
  # lock (HostReach) — "now rather than discovered by a red run"; this is
  # the same for the operator, whose login mints the registration tokens
  # and, with --org, reads and converges the runner groups. Without it the
  # first refusal was a 403 backtrace out of RunnerGroups, after sudo and
  # brew had already run.
  #
  # A precondition is a **probe** — the capability call itself — not a
  # comparison against the token's scope list: fine-grained PATs and
  # installation tokens report no scopes at all (gh and GhAuth both treat
  # that as "unknown, proceed"), and the call is the only truthful test.
  # The classic-token scope is the *fix*, not the check: it is what the
  # refusal names, and what the offered `gh auth refresh` requests.
  class OperatorAccess
    extend T::Sig

    # The login cannot do what the registration needs, and either no
    # terminal was there to offer the refresh or the refresh did not help.
    class RefusedError < RuntimeError; end

    # One thing the login must be able to do: the probe that proves it,
    # the words for its refusal (what register needs it for), and the
    # classic scope that grants it.
    class Precondition < T::Struct
      extend T::Sig

      # "read d3mlabs's runner groups" — the capability, as a verb phrase.
      const :capability, String
      # Why register needs it.
      const :purpose, String
      # The classic OAuth scope that grants it (`gh auth refresh -s`).
      const :scope, String
      # Raises RunnerRegistry::QueryError when the login is refused.
      const :probe, T.proc.void

      # The one command that widens a classic login to this scope.
      #
      # @return [String]
      sig { returns(String) }
      def fix
        "gh auth refresh -h github.com -s #{scope}"
      end
    end

    # Runs `gh auth refresh` for a scope; true when it succeeded. gh does
    # the browser round-trip itself.
    Refresher = T.type_alias { T.proc.params(scope: String).returns(T::Boolean) }

    # The one way a login is widened by default: gh's own refresh, which
    # prompts and opens the browser itself; its exit status is the answer.
    DEFAULT_REFRESHER = T.let(
      ->(scope) { Kernel.system("gh", "auth", "refresh", "-h", "github.com", "-s", scope) == true },
      Refresher,
    )

    # @param registry [#group, #find] the GitHub boundary the probes go through
    # @param refresher [Proc] how a refresh is run (injectable for tests)
    sig do
      params(
        registry: T.untyped,
        refresher: Refresher,
      ).void
    end
    def initialize(registry:, refresher: DEFAULT_REFRESHER)
      @registry = registry
      @refresher = refresher
    end

    # Probe what a registration at `scope` needs of the operator's login;
    # refused, say so with the fix, offer the refresh at a terminal and
    # probe once more. The offer is a yes/no, no by default; with no
    # terminal to ask at it is not taken.
    #
    # @param scope [String] "owner" (org) or "owner/repo"
    # @param org [Boolean] whether the registration is org-scoped
    # @param ui [Dev::Ui] the refusal is noted on it, then the yes/no asked — nil (no terminal) is a no
    # @return [void]
    # @raise [RefusedError] when the login cannot, and a refresh did not or could not help
    sig { params(scope: String, org: T::Boolean, ui: Dev::Ui).void }
    def check!(scope:, org:, ui:)
      precondition = org ? org_precondition(scope) : repo_precondition(scope)
      refusal = refusal_of(precondition)
      return if refusal.nil?

      ui.note("{{x}} #{headline(precondition, refusal)}")
      if ui.confirm("Run `#{precondition.fix}` now?") && @refresher.call(precondition.scope)
        refusal = refusal_of(precondition)
        return if refusal.nil?
      end

      raise RefusedError, "#{headline(precondition, refusal)}\n  #{precondition.fix}\nthen re-run dev runner register."
    end

    private

    # --org: the org's runner groups, which register lists, creates and
    # converges, with the registration tokens minted at the same scope.
    #
    # @param org [String]
    # @return [Precondition]
    sig { params(org: String).returns(Precondition) }
    def org_precondition(org)
      Precondition.new(
        capability: "read #{org}'s runner groups",
        purpose: "register converges the slots' group there and mints the org's registration tokens (an org admin's login)",
        scope: "admin:org",
        probe: -> { @registry.group(org: org, name: "Default") },
      )
    end

    # Repo scope: the repo's runners, which only a repo admin lists — the
    # same admin who may mint its registration tokens.
    #
    # @param repo [String]
    # @return [Precondition]
    sig { params(repo: String).returns(Precondition) }
    def repo_precondition(repo)
      Precondition.new(
        capability: "read #{repo}'s runners",
        purpose: "register enrolls there and mints its registration tokens (a repo admin's login)",
        scope: "repo",
        probe: -> { @registry.find(scope: repo, name: "") },
      )
    end

    # GitHub's words when the probe is refused; nil when it passes.
    #
    # @param precondition [Precondition]
    # @return [String, nil]
    sig { params(precondition: Precondition).returns(T.nilable(String)) }
    def refusal_of(precondition)
      precondition.probe.call
      nil
    rescue RunnerRegistry::QueryError => e
      e.message
    end

    # @param precondition [Precondition]
    # @param refusal [String]
    # @return [String]
    sig { params(precondition: Precondition, refusal: String).returns(String) }
    def headline(precondition, refusal)
      "your gh login cannot #{precondition.capability} — #{precondition.purpose}. GitHub: #{refusal}"
    end
  end
end

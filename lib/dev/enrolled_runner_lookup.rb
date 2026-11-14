# typed: strict
# frozen_string_literal: true

require "dev/enrolled_runner"
require "dev/runner_registry"
require "dev/runner_setup"

module Dev
  # Whether the enclosing checkout's enrolled runner is available — the
  # question the remote dispatch asks before targeting it (native when
  # the host rule passes, else the enrolled runner, else the project's
  # container). "Available" is the Actions API's answer, read
  # live and recorded nowhere: a runner at the repo's scope carrying the
  # repo's label, online — the same health contract register reads of
  # its own enrollment (RunnerRegistry::Runner#online?). A busy runner is
  # available; the job queues behind it. A runner the org enrolled under
  # the same label serves the repo too in GitHub's routing, but it is a
  # pool, named with `--runner <label>`, not the repo's
  # enrolled runner; listing it would also need admin:org, which a Mac's
  # operator login need not hold.
  #
  # GitHub unreachable is an error, never "no runner": the remote dispatch
  # needs GitHub for the snapshot push and the workflow run anyway, and a
  # silent nil would send a Win64 build into the local container on a
  # flaky connection.
  class EnrolledRunnerLookup
    extend T::Sig

    # Answers "owner/repo" for the enclosing checkout; the gh boundary.
    RepoResolver = T.type_alias { T.proc.returns(String) }

    # @param registry [RunnerRegistry] the GitHub-side runner reader
    # @param repo_resolver [Proc] the checkout's repo as GitHub spells it
    #   — RunnerSetup.current_repo, the one `gh repo view` seam register
    #   derives its label from, so both sides derive from the same name
    sig { params(registry: RunnerRegistry, repo_resolver: RepoResolver).void }
    def initialize(registry: RunnerRegistry.new, repo_resolver: -> { RunnerSetup.current_repo })
      @registry = registry
      @repo_resolver = repo_resolver
    end

    # The checkout's enrolled runner when GitHub lists one online under
    # its label at its scope; nil when none is — the repo has no runner
    # the remote dispatch can target.
    #
    # @return [EnrolledRunner, nil]
    # @raise [RunnerSetup::Error] when gh cannot resolve the checkout
    # @raise [EnrolledRunner::MalformedRepoError] when what it resolved is not an owner/repo
    # @raise [RunnerRegistry::QueryError] when GitHub cannot be queried
    sig { returns(T.nilable(EnrolledRunner)) }
    def available
      enrolled = EnrolledRunner.for(@repo_resolver.call)
      return nil if @registry.available(scope: enrolled.scope, label: enrolled.label).nil?

      enrolled
    end
  end
end

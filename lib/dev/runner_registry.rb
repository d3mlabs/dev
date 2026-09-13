# typed: strict
# frozen_string_literal: true

require "json"

require "dev/runner_setup"

module Dev
  # The GitHub-side view of the self-hosted runners enrolled at a scope:
  # find one by name, amend its custom labels in place. Labels have exactly
  # one home — GitHub — so this is both how register converges an existing
  # enrollment's labels without re-enrolling and how status reports them
  # (plans#26: inspected, never recorded).
  #
  # The gh CLI boundary rides the same Executor seam RunnerSetup uses, so
  # tests exercise the orchestration without the network.
  class RunnerRegistry
    extend T::Sig

    # GitHub could not be queried (offline, unauthenticated) — distinct
    # from a runner genuinely absent at the scope (find returns nil).
    class QueryError < StandardError; end

    # The label amend was refused (permissions, deleted runner).
    class AmendError < StandardError; end

    # One enrolled runner, as the amendable subset of GitHub's record:
    # custom labels only — the read-only ones (self-hosted, OS, arch) are
    # GitHub's, not ours to converge.
    class Runner < T::Struct
      const :id, Integer
      const :custom_labels, T::Array[String]
    end

    # @param executor [#capture] CLI boundary (injectable for tests)
    sig { params(executor: T.untyped).void }
    def initialize(executor: RunnerSetup::Executor.new)
      @exec = executor
    end

    # The runner enrolled under `name` at `scope`, or nil when none is.
    #
    # @param scope [String] "owner/repo" or "owner"
    # @param name [String] the runner's GitHub-side name
    # @return [Runner, nil]
    # @raise [QueryError] when GitHub can't be queried — loud, never a
    #   silent not-found, so callers can tell "gone" from "unknown"
    sig { params(scope: String, name: String).returns(T.nilable(Runner)) }
    def find(scope:, name:)
      out, err, ok = @exec.capture("gh", "api", "--paginate", "#{api_base(scope)}/actions/runners", "--jq", ".runners[]")
      raise QueryError, "could not list the runners at #{scope}: #{err.strip}" unless ok

      record = out.each_line.map { |line| JSON.parse(line) }.find { |runner| runner["name"] == name }
      return nil if record.nil?

      custom = Array(record["labels"]).select { |label| label["type"] == "custom" }.map { |label| label["name"].to_s }
      Runner.new(id: Integer(record.fetch("id")), custom_labels: custom)
    end

    # Replace the runner's custom labels with `labels` (GitHub's PUT
    # semantics: the full custom set, read-only labels untouched). This is
    # the no-re-enrollment amend path: the service, its name, and its dir
    # all stay put.
    #
    # @param scope [String] "owner/repo" or "owner"
    # @param runner_id [Integer]
    # @param labels [Array<String>] the desired custom label set
    # @return [void]
    # @raise [AmendError] when the PUT is refused
    sig { params(scope: String, runner_id: Integer, labels: T::Array[String]).void }
    def amend!(scope:, runner_id:, labels:)
      argv = ["gh", "api", "-X", "PUT", "#{api_base(scope)}/actions/runners/#{runner_id}/labels"]
      argv += labels.flat_map { |label| ["-f", "labels[]=#{label}"] }
      _out, err, ok = @exec.capture(*argv)
      raise AmendError, "could not amend the labels of runner #{runner_id} at #{scope}: #{err.strip}" unless ok
    end

    private

    # The API path prefix for a scope, following its shape (repos/... for
    # "owner/repo", orgs/... for a bare org) — same convention as
    # RunnerSetup's token minting.
    #
    # @param scope [String]
    # @return [String]
    sig { params(scope: String).returns(String) }
    def api_base(scope)
      scope.include?("/") ? "repos/#{scope}" : "orgs/#{scope}"
    end
  end
end

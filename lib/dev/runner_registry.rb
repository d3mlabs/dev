# typed: strict
# frozen_string_literal: true

require "json"

require "dev/runner_setup"

module Dev
  # The GitHub-side view of the self-hosted runners enrolled at a scope:
  # find one by name, ask whether one carrying a label is available, amend
  # a runner's custom labels in place. Labels have exactly one home —
  # GitHub — so this is how register converges an existing enrollment's
  # labels without re-enrolling, how status reports them, and how the
  # remote dispatch learns a repo's enrolled runner is there to target
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

    # One enrolled runner, as the subset of GitHub's record dev reads:
    # the amendable custom labels — the read-only ones (self-hosted, OS,
    # arch) are GitHub's, not ours to converge — and GitHub's health
    # verdict, which tells a registration something is running from one
    # nothing is.
    class Runner < T::Struct
      extend T::Sig

      const :id, Integer
      const :custom_labels, T::Array[String]

      # GitHub's word: "online" when a listener holds the registration's
      # session, "offline" otherwise.
      const :status, String

      # The one health contract: a listener is connected. `busy` is a
      # different question (is it running a job) and never enters here.
      #
      # @return [Boolean]
      sig { returns(T::Boolean) }
      def online? = status == "online"

      # Whether the runner advertises a custom label — compared the way
      # GitHub routes a `runs-on` demand against it, case-insensitively.
      #
      # @param label [String]
      # @return [Boolean]
      sig { params(label: String).returns(T::Boolean) }
      def carries?(label) = custom_labels.any? { |custom| custom.casecmp?(label) }
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
      record = runners(scope).find { |candidate| candidate["name"] == name }
      return nil if record.nil?

      runner_from(record)
    end

    # The first runner at `scope` that is online and carries `label` —
    # "available" as the remote dispatch means it: GitHub would route a
    # `runs-on: [self-hosted, <label>]` job in that scope to it now (busy
    # included; the job queues behind it). nil when no online runner
    # carries the label: none enrolled, or enrolled and offline — a
    # registration nothing is running, which is not a host to dispatch
    # to. Only the enrollment's own custom labels count; GitHub's
    # read-only ones (self-hosted, the OS, the arch) name no enrollment.
    #
    # @param scope [String] "owner/repo" or "owner"
    # @param label [String] the custom label the job would demand
    # @return [Runner, nil]
    # @raise [QueryError] when GitHub can't be queried — loud, so an
    #   outage is never read as "no runner, build elsewhere"
    sig { params(scope: String, label: String).returns(T.nilable(Runner)) }
    def available(scope:, label:)
      runners(scope).lazy.map { |record| runner_from(record) }.find { |runner| runner.online? && runner.carries?(label) }
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

    # Every runner GitHub lists at a scope, one record per `--jq
    # .runners[]` line, paginated so a scope with many is read whole.
    #
    # @param scope [String] "owner/repo" or "owner"
    # @return [Array<Hash>] GitHub's runner objects
    # @raise [QueryError] when GitHub can't be queried
    sig { params(scope: String).returns(T::Array[T::Hash[String, T.untyped]]) }
    def runners(scope)
      out, err, ok = @exec.capture("gh", "api", "--paginate", "#{api_base(scope)}/actions/runners", "--jq", ".runners[]")
      raise QueryError, "could not list the runners at #{scope}: #{err.strip}" unless ok

      out.each_line.map { |line| JSON.parse(line) }
    end

    # The subset of a runner record dev reads (see Runner).
    #
    # @param record [Hash] GitHub's runner object
    # @return [Runner]
    sig { params(record: T::Hash[String, T.untyped]).returns(Runner) }
    def runner_from(record)
      custom = Array(record["labels"]).select { |label| label["type"] == "custom" }.map { |label| label["name"].to_s }
      Runner.new(id: Integer(record.fetch("id")), custom_labels: custom, status: record.fetch("status").to_s)
    end

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

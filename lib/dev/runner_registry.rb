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
      def online?
        status == "online"
      end

      # Whether the runner advertises a custom label — compared the way
      # GitHub routes a `runs-on` demand against it, case-insensitively.
      #
      # @param label [String]
      # @return [Boolean]
      sig { params(label: String).returns(T::Boolean) }
      def carries?(label)
        custom_labels.any? { |custom| custom.casecmp?(label) }
      end
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

    # One of an org's runner groups — GitHub's partition of *who may use*
    # a runner (plans#26: labels say what a host can do, groups say which
    # repos see it): its repository access (visibility and, when
    # "selected", the selected repositories; whether public repos may use
    # it at all) and its workflow access (the workflows pinned as the only
    # ones that may land jobs on it — plans#5 H3). Read and converged,
    # never recorded.
    class Group < T::Struct
      extend T::Sig

      const :id, Integer
      const :name, String

      # GitHub's word: "all", "selected" or "private".
      const :visibility, String

      # Whether a public repository may use these runners at all.
      const :allows_public_repositories, T::Boolean

      # Whether only `selected_workflows` may land jobs here.
      const :restricted_to_workflows, T::Boolean

      # `owner/repo/.github/workflows/<file>.yml@<ref>`, when restricted.
      const :selected_workflows, T::Array[String]

      # Whether the group's repository access is a selection to converge.
      sig { returns(T::Boolean) }
      def selected?
        visibility == "selected"
      end

      # Whether at least one workflow is pinned: the state the public-repo
      # rule (plans#5 H3) wants. Restricted to *no* workflow is what an
      # incomplete PATCH leaves — a group no job can reach, not a safe one.
      sig { returns(T::Boolean) }
      def pinned?
        restricted_to_workflows && !selected_workflows.empty?
      end
    end

    # A repository a group is visible to, as GitHub lists it.
    class GroupRepository < T::Struct
      const :id, Integer

      # "owner/repo"
      const :full_name, String
    end

    # A repository as GitHub records it: the id a group selection is
    # written in, and its visibility (the fact the workflow-pin invariant
    # turns on).
    class Repository < T::Struct
      extend T::Sig

      const :id, Integer
      const :full_name, String

      # GitHub's word: "public", "private" or "internal".
      const :visibility, String

      sig { returns(T::Boolean) }
      def public?
        visibility == "public"
      end
    end

    # The org's runner group of that name, or nil when none is.
    #
    # @param org [String]
    # @param name [String]
    # @return [Group, nil]
    # @raise [QueryError]
    sig { params(org: String, name: String).returns(T.nilable(Group)) }
    def group(org:, name:)
      groups(org).find { |group| group.name == name }
    end

    # Create a runner group with the given access (GitHub's POST; the
    # selected repositories start empty and are converged separately —
    # setting visibility and repositories in one call is the order plans#5
    # found to drop the list).
    #
    # @param org [String]
    # @param name [String]
    # @param visibility [String]
    # @param allows_public_repositories [Boolean]
    # @param selected_workflows [Array<String>] pins; empty = unrestricted
    # @return [Group] as GitHub records it
    # @raise [AmendError] when the POST is refused
    sig do
      params(org: String, name: String, visibility: String, allows_public_repositories: T::Boolean, selected_workflows: T::Array[String])
        .returns(Group)
    end
    def create_group!(org:, name:, visibility:, allows_public_repositories:, selected_workflows:)
      argv = ["gh", "api", "-X", "POST", "orgs/#{org}/actions/runner-groups", "-f", "name=#{name}", "-f", "visibility=#{visibility}",
              "-F", "allows_public_repositories=#{allows_public_repositories}",
              "-F", "restricted_to_workflows=#{!selected_workflows.empty?}"]
      argv += selected_workflows.flat_map { |workflow| ["-f", "selected_workflows[]=#{workflow}"] }
      out, err, ok = @exec.capture(*argv)
      raise AmendError, "could not create runner group '#{name}' at #{org}: #{err.strip}" unless ok

      parse_group(JSON.parse(out))
    end

    # Change a group's access fields. GitHub's PATCH is not the partial
    # update its verb suggests (dev#473, probed live): an omitted
    # `selected_workflows` is read as none — the pins are wiped — and a
    # PATCH naming `visibility`, even to its current value, clears the
    # selected repositories (plans#5 H3). So the pins are always sent in
    # full (the caller passes the current ones when changing something
    # else), and visibility is named only when the caller means to flip
    # it — after which the selection must be written again.
    #
    # @param org [String]
    # @param group_id [Integer]
    # @param selected_workflows [Array<String>] the whole pin set; empty = unrestricted
    # @param visibility [String, nil] only when flipping it
    # @param allows_public_repositories [Boolean, nil]
    # @return [Group] as GitHub records it after the change
    # @raise [AmendError] when the PATCH is refused
    sig do
      params(org: String, group_id: Integer, selected_workflows: T::Array[String], visibility: T.nilable(String),
        allows_public_repositories: T.nilable(T::Boolean)).returns(Group)
    end
    def update_group!(org:, group_id:, selected_workflows:, visibility: nil, allows_public_repositories: nil)
      argv = ["gh", "api", "-X", "PATCH", "orgs/#{org}/actions/runner-groups/#{group_id}"]
      argv += ["-f", "visibility=#{visibility}"] if visibility
      argv += ["-F", "allows_public_repositories=#{allows_public_repositories}"] unless allows_public_repositories.nil?
      argv += ["-F", "restricted_to_workflows=#{!selected_workflows.empty?}"]
      argv += selected_workflows.flat_map { |workflow| ["-f", "selected_workflows[]=#{workflow}"] }
      out, err, ok = @exec.capture(*argv)
      raise AmendError, "could not update runner group #{group_id} at #{org}: #{err.strip}" unless ok

      parse_group(JSON.parse(out))
    end

    # The group a runner sits in, found by asking each group for its
    # runners (a runner's own record does not say). nil when no group
    # lists it.
    #
    # @param org [String]
    # @param runner_id [Integer]
    # @return [Group, nil]
    # @raise [QueryError]
    sig { params(org: String, runner_id: Integer).returns(T.nilable(Group)) }
    def group_of(org:, runner_id:)
      groups(org).find do |group|
        out, err, ok = @exec.capture("gh", "api", "--paginate", "orgs/#{org}/actions/runner-groups/#{group.id}/runners", "--jq", ".runners[].id")
        raise QueryError, "could not list the runners of group #{group.name} at #{org}: #{err.strip}" unless ok

        out.each_line.map { |line| Integer(line.strip) }.include?(runner_id)
      end
    end

    # The repositories a group is visible to (its selection; empty when
    # the group's visibility is not "selected").
    #
    # @param org [String]
    # @param group_id [Integer]
    # @return [Array<GroupRepository>]
    # @raise [QueryError]
    sig { params(org: String, group_id: Integer).returns(T::Array[GroupRepository]) }
    def group_repositories(org:, group_id:)
      out, err, ok = @exec.capture("gh", "api", "--paginate", "orgs/#{org}/actions/runner-groups/#{group_id}/repositories", "--jq", ".repositories[]")
      raise QueryError, "could not list the repositories of group #{group_id} at #{org}: #{err.strip}" unless ok

      out.each_line.map do |line|
        record = JSON.parse(line)
        GroupRepository.new(id: Integer(record.fetch("id")), full_name: record.fetch("full_name").to_s)
      end
    end

    # Replace the group's selected repositories (GitHub's PUT semantics:
    # the full set).
    #
    # @param org [String]
    # @param group_id [Integer]
    # @param repository_ids [Array<Integer>]
    # @return [void]
    # @raise [AmendError] when the PUT is refused
    sig { params(org: String, group_id: Integer, repository_ids: T::Array[Integer]).void }
    def select_group_repositories!(org:, group_id:, repository_ids:)
      argv = ["gh", "api", "-X", "PUT", "orgs/#{org}/actions/runner-groups/#{group_id}/repositories"]
      argv += repository_ids.flat_map { |id| ["-F", "selected_repository_ids[]=#{id}"] }
      _out, err, ok = @exec.capture(*argv)
      raise AmendError, "could not set the repositories of group #{group_id} at #{org}: #{err.strip}" unless ok
    end

    # Move a runner into a group (idempotent when it is there already).
    #
    # @param org [String]
    # @param group_id [Integer]
    # @param runner_id [Integer]
    # @return [void]
    # @raise [AmendError] when the PUT is refused
    sig { params(org: String, group_id: Integer, runner_id: Integer).void }
    def place_in_group!(org:, group_id:, runner_id:)
      _out, err, ok = @exec.capture("gh", "api", "-X", "PUT", "orgs/#{org}/actions/runner-groups/#{group_id}/runners/#{runner_id}")
      raise AmendError, "could not move runner #{runner_id} into group #{group_id} at #{org}: #{err.strip}" unless ok
    end

    # A repository as GitHub records it.
    #
    # @param repo [String] "owner/repo"
    # @return [Repository]
    # @raise [QueryError] when the repo cannot be read (absent, or not reachable)
    sig { params(repo: String).returns(Repository) }
    def repository(repo)
      out, err, ok = @exec.capture("gh", "api", "repos/#{repo}")
      raise QueryError, "could not read #{repo}: #{err.strip}" if !ok || out.strip.empty?

      record = JSON.parse(out)
      Repository.new(id: Integer(record.fetch("id")), full_name: record.fetch("full_name").to_s, visibility: record.fetch("visibility").to_s)
    end

    private

    # Every runner group of an org.
    #
    # @param org [String]
    # @return [Array<Group>]
    # @raise [QueryError]
    sig { params(org: String).returns(T::Array[Group]) }
    def groups(org)
      out, err, ok = @exec.capture("gh", "api", "--paginate", "orgs/#{org}/actions/runner-groups", "--jq", ".runner_groups[]")
      raise QueryError, "could not list the runner groups at #{org}: #{err.strip}" unless ok

      out.each_line.map { |line| parse_group(JSON.parse(line)) }
    end

    # @param record [Hash] a runner group as the API returns it
    # @return [Group]
    sig { params(record: T::Hash[String, T.untyped]).returns(Group) }
    def parse_group(record)
      Group.new(
        id: Integer(record.fetch("id")),
        name: record.fetch("name").to_s,
        visibility: record.fetch("visibility").to_s,
        allows_public_repositories: record.fetch("allows_public_repositories", false) == true,
        restricted_to_workflows: record.fetch("restricted_to_workflows", false) == true,
        selected_workflows: Array(record.fetch("selected_workflows", [])).map(&:to_s),
      )
    end

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

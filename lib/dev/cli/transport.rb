# typed: strict
# frozen_string_literal: true

require "pathname"
require "stringio"
require "dev/actions_job_context"
require "dev/environment_image"
require "dev/lifecycle"
require "dev/project_container"

module Dev
  module Cli
    # How a remote dispatch reaches the host that runs the verb: the
    # second level of the sealed Dispatch type. The contract is a
    # workspace: a transport delivers the project's tree to its host for
    # the duration of a run (`with_workspace`), however that host needs
    # it delivered, and runs the invocation in what it delivered (`run`).
    # The caller shape is written once — refuse, deliver, print the
    # crossing, run — in Dispatch::Remote; what differs per host is the
    # delivery and how the verb is *invoked* and *watched*.
    # `ActionsRunner` delivers by the sync step (the host is another
    # machine: commit, push a snapshot branch, dispatch dev's generic
    # workflow on it, watch the run, delete the branch); `LocalContainer`
    # delivers by bind-mounting the checkout itself (the host is this
    # machine), `docker exec`s into the project's container and is watched
    # by waiting.
    #
    # Neither a build host (the (machine, platform) pair — the
    # result) nor a placement (the host rule's input): a transport is the
    # means, named by the runner label the host answers to.
    module Transport
      extend T::Sig
      extend T::Helpers
      # Every includer is an Object; this tells Sorbet the Object protocol
      # exists on a value typed as the interface.
      include Kernel
      abstract!
      sealed!

      # Builds the sync step over a tree: the delivery an adapter that
      # pushes a snapshot branch uses. The tree is `with_workspace`'s input,
      # not the transport's, so a factory stands in for the instance.
      SyncFor = T.type_alias { T.proc.params(root: Pathname).returns(Lifecycle::SnapshotSync) }

      # The sync step a caller gets by default: the lifecycle's snapshot
      # sync over the checkout.
      DEFAULT_SYNC_FOR = T.let(->(root) { Lifecycle::SnapshotSync.new(root:) }, SyncFor)

      # The label the host answers to: what a runner's snapshot branch is
      # named for and what the host rule resolves by.
      #
      # @return [String]
      sig { abstract.returns(String) }
      def runner; end

      # Where the verb goes, as the crossing line says it: `on <label>` for
      # a runner, `in <image> (container)` for the container.
      #
      # @return [String]
      sig { abstract.returns(String) }
      def destination; end

      # Refuse before anything leaves the machine when the transport cannot
      # carry a verb (the project carries no copy of the workflow; the
      # engine is down; this dev already runs inside an Actions job).
      #
      # @return [void]
      sig { abstract.void }
      def assert_ready!; end

      # Deliver the tree to the host as a workspace for the block's
      # duration, and take it back after, however the block ends.
      #
      # @param tree [Pathname] the project's checkout
      # @yieldparam workspace [Lifecycle::Workspace] what the host holds of the tree
      # @yieldreturn [R] what the caller ran there
      # @return [R] the block's value
      sig do
        abstract.type_parameters(:R)
          .params(tree: Pathname, blk: T.proc.params(workspace: Lifecycle::Workspace).returns(T.type_parameter(:R)))
          .returns(T.type_parameter(:R))
      end
      def with_workspace(tree, &blk); end

      # Run the verb on the host in the workspace, and return once it has
      # finished there.
      #
      # @param invocation [Lifecycle::VerbInvocation]
      # @param workspace [Lifecycle::Workspace] what this transport delivered
      # @return [void]
      sig { abstract.params(invocation: Lifecycle::VerbInvocation, workspace: Lifecycle::Workspace).void }
      def run(invocation, workspace:); end

      # A GitHub Actions runner carrying a label — the repo's enrolled
      # runner (the repo's name), or a pool named with `--runner` — reached
      # through dev's generic workflow (Lifecycle::LifecycleWorkflow). The
      # host is another machine, so the tree is delivered by the sync step
      # (Lifecycle::SnapshotSync): committed, pushed to
      # `dev/build/<label>/<id>`, deleted when the run returns. The
      # project's copy of the workflow is dispatched on that branch with the
      # verb as its `verbs` input, the run that dispatch made is found by
      # the branch and watched to its verdict, and the artifact comes back
      # as a workflow artifact when the invocation asks (`--fetch`).
      #
      # A verb already inside an Actions job never takes this transport:
      # the verb got there because a runner was told to run it, and a runner
      # that then finds itself not to be the build's environment is
      # misprovisioned — re-dispatching would hide that behind a loop, once
      # onto itself or forever between two. The adapter that would loop is
      # the one that refuses (`assert_ready!`).
      class ActionsRunner
        extend T::Sig
        extend T::Helpers
        include Transport
        final!

        # The run ended without GitHub's success verdict; the message
        # carries the verb, the label and the run's page.
        class RemoteVerbFailedError < RuntimeError; end

        # The workspace handed in is not a snapshot branch — another
        # transport's delivery, which no workflow can be dispatched on.
        class WorkspaceNotSnapshotError < ArgumentError; end

        # This dev runs inside an Actions job, and a job never dispatches
        # a job.
        class DispatchFromJobError < RuntimeError; end

        sig(:final) { override.returns(String) }
        attr_reader :runner

        sig(:final) { override.returns(String) }
        def destination
          "on #{@runner}"
        end

        # @param runner [String] the label the job demands beside `self-hosted`
        # @param runs [Lifecycle::WorkflowRuns] the forge's side of the dispatch
        # @param workflow [Lifecycle::LifecycleWorkflow] the project's copy of the generic workflow
        # @param sync_for [Proc] the sync step over a tree (SyncFor)
        # @param inside_job [Boolean] whether this dev runs inside an Actions job
        # @param out [IO, StringIO] where the run's page is named
        sig(:final) do
          params(
            runner: String,
            runs: Lifecycle::WorkflowRuns,
            workflow: Lifecycle::LifecycleWorkflow,
            sync_for: SyncFor,
            inside_job: T::Boolean,
            out: T.any(IO, StringIO),
          ).void
        end
        def initialize(runner:, runs:, workflow:, sync_for: DEFAULT_SYNC_FOR, inside_job: ActionsJobContext.inside?, out: $stdout)
          @runner = runner
          @runs = runs
          @workflow = workflow
          @sync_for = sync_for
          @inside_job = inside_job
          @out = out
        end

        # @raise [DispatchFromJobError] inside an Actions job
        # @raise [Lifecycle::LifecycleWorkflow::WorkflowMissingError]
        sig(:final) { override.void }
        def assert_ready!
          if @inside_job
            raise DispatchFromJobError,
              "the verb would leave this Actions job for runner `#{@runner}`: a job never dispatches a job — " \
                "the job's runner is not the build's environment; provision it from the image, or name a runner that is"
          end

          @workflow.assert_installed!
        end

        # The sync step: the tree pushed as a snapshot branch named for the
        # label, for the block's duration.
        #
        # @raise [Lifecycle::WorkflowTriggers::UnfilteredPushTriggerError] and
        #   the sync step's other refusals, before anything is pushed
        sig(:final) do
          override.type_parameters(:R)
            .params(tree: Pathname, blk: T.proc.params(workspace: Lifecycle::Workspace).returns(T.type_parameter(:R)))
            .returns(T.type_parameter(:R))
        end
        def with_workspace(tree, &blk)
          @sync_for.call(tree).sync(runner: @runner) { |snapshot| yield Lifecycle::Workspace::Snapshot.new(snapshot) }
        end

        # @raise [WorkspaceNotSnapshotError]
        # @raise [RemoteVerbFailedError]
        # @raise [Lifecycle::WorkflowRuns::RunNotListedError]
        # @raise [Lifecycle::WorkflowRuns::WatchLostError]
        # @raise [Lifecycle::Gh::CommandFailedError] the dispatch, the verdict or the download refused
        sig(:final) { override.params(invocation: Lifecycle::VerbInvocation, workspace: Lifecycle::Workspace).void }
        def run(invocation, workspace:)
          workflow = Lifecycle::LifecycleWorkflow::FILE_NAME
          branch = snapshot_of(workspace).branch
          @runs.dispatch(workflow:, ref: branch.name, inputs: @workflow.inputs(invocation, runner: @runner))
          run = @runs.locate(workflow:, branch:)
          @out.puts "dispatched `dev #{invocation}` on #{@runner}: #{run.url}"
          finished = @runs.watch(run)
          unless finished.succeeded?
            raise RemoteVerbFailedError, "`dev #{invocation}` on #{@runner} ended with #{finished.conclusion || finished.status}: #{run.url}"
          end

          fetch = invocation.fetch
          return if fetch.nil?

          @runs.download(finished, name: fetch.name, into: fetch.into)
          @out.puts "fetched #{fetch.name} → #{fetch.into}"
        end

        private

        # The snapshot the workspace carries: the only shape this transport
        # delivers, read back from the sealed type in one place.
        #
        # @param workspace [Lifecycle::Workspace]
        # @return [Lifecycle::Snapshot]
        # @raise [WorkspaceNotSnapshotError] for a workspace another transport delivered
        sig(:final) { params(workspace: Lifecycle::Workspace).returns(Lifecycle::Snapshot) }
        def snapshot_of(workspace)
          case workspace
          when Lifecycle::Workspace::Snapshot
            workspace.snapshot
          when Lifecycle::Workspace::Mounted
            raise WorkspaceNotSnapshotError,
              "a runner is dispatched on a snapshot branch, not #{workspace.description}: a mount is the container's delivery"
          else
            T.absurd(workspace)
          end
        end
      end

      # The project's own build container as the degenerate runner: the
      # host is this machine, so the tree is delivered by bind-mounting the
      # checkout into the container at its own path — nothing committed,
      # pushed or fetched; what the verb writes is the checkout — and the
      # verb's words are run there by the dev inside (`dev build <build>`),
      # reached by `docker exec` (ProjectContainer). Watching is waiting:
      # the exec's exit status is the verdict. The artifact lands in the
      # container's data root; when the invocation asks (`--fetch`) it is
      # copied out into the host's store — unless the two are one (a Linux
      # host's bind mount), where it already is. Last in the resolution
      # order and forced by `--container` (DispatchResolver).
      class LocalContainer
        extend T::Sig
        extend T::Helpers
        include Transport
        final!

        # The label the container answers to: the degenerate runner's.
        RUNNER = "container"

        # The verb exited nonzero inside; the message carries the verb, the
        # image and the status.
        class ContainerVerbFailedError < RuntimeError
          extend T::Sig

          sig { returns(Integer) }
          attr_reader :exit_status

          # @param message [String]
          # @param exit_status [Integer] the container process's
          sig { params(message: String, exit_status: Integer).void }
          def initialize(message, exit_status:)
            @exit_status = exit_status
            super(message)
          end
        end

        # @param image [EnvironmentImage] the build's environment, run as a container
        # @param containers [ProjectContainer] the way into the project's containers
        # @param out [IO, StringIO] where the fetch is reported
        sig(:final) { params(image: EnvironmentImage, containers: ProjectContainer, out: T.any(IO, StringIO)).void }
        def initialize(image:, containers:, out: $stdout)
          @image = image
          @containers = containers
          @out = out
        end

        sig(:final) { override.returns(String) }
        def runner
          RUNNER
        end

        sig(:final) { override.returns(String) }
        def destination
          @containers.destination(@image)
        end

        # @raise [ProjectContainer::EngineUnavailableError]
        sig(:final) { override.void }
        def assert_ready!
          @containers.assert_engine_up!
        end

        # The checkout itself: mounted into the container by the run, there
        # is nothing to deliver ahead or take back after.
        sig(:final) do
          override.type_parameters(:R)
            .params(tree: Pathname, blk: T.proc.params(workspace: Lifecycle::Workspace).returns(T.type_parameter(:R)))
            .returns(T.type_parameter(:R))
        end
        def with_workspace(tree, &blk)
          yield Lifecycle::Workspace::Mounted.new(tree)
        end

        # @raise [ContainerVerbFailedError]
        # @raise [EngineResourcesCheck::UndersizedEngineError]
        # @raise [ProjectContainer::WorkspaceNotMountedError]
        # @raise [BuildContainer::CopyOutFailedError] the fetch refused
        sig(:final) { override.params(invocation: Lifecycle::VerbInvocation, workspace: Lifecycle::Workspace).void }
        def run(invocation, workspace:)
          status = @containers.run(@image, argv: ["dev", *invocation.words], workspace:)
          unless status.zero?
            raise ContainerVerbFailedError.new("`dev #{invocation}` #{destination} exited #{status}", exit_status: status)
          end

          fetch = invocation.fetch
          return if fetch.nil?

          @containers.fetch(@image, into: fetch.into)
          @out.puts "fetched #{fetch.name} → #{fetch.into}"
        end
      end
    end
  end
end

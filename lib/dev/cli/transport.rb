# typed: strict
# frozen_string_literal: true

require "pathname"
require "stringio"
require "dev/container_workspace"
require "dev/environment_image"
require "dev/lifecycle"
require "dev/project_container"

module Dev
  module Cli
    # How a remote dispatch reaches the host that runs the verb (dev#192,
    # K8): the second level of the sealed Dispatch type. The remote path —
    # snapshot the tree, push it, cross, run the verb there, leave the
    # artifact with the host — is written once in Dispatch::Remote against
    # this interface; what differs per host is how the verb is *invoked*
    # and *watched* and how the host gets the snapshot: `ActionsRunner`
    # dispatches dev's generic workflow on the snapshot branch and watches
    # the run (the job's checkout fetches the snapshot); `LocalContainer`
    # (dev#421) `docker exec`s into the project's container, which fetches
    # the branch itself into its own workspace and is watched by waiting.
    #
    # Neither a build host (ADR-0008's (machine, platform) pair — the
    # result) nor a placement (the host rule's input): a transport is the
    # means, named by the runner label the snapshot branch is minted for.
    module Transport
      extend T::Sig
      extend T::Helpers
      # Every includer is an Object; this tells Sorbet the Object protocol
      # exists on a value typed as the interface.
      include Kernel
      abstract!
      sealed!

      # The label the host answers to: what the snapshot branch is named
      # for and what the crossing line prints.
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
      # engine is down).
      #
      # @return [void]
      sig { abstract.void }
      def assert_ready!; end

      # Run the verb on the host at the snapshot, and return once it has
      # finished there.
      #
      # @param invocation [Lifecycle::VerbInvocation]
      # @param snapshot [Lifecycle::Snapshot] the pushed tree
      # @return [void]
      sig { abstract.params(invocation: Lifecycle::VerbInvocation, snapshot: Lifecycle::Snapshot).void }
      def run(invocation, snapshot:); end

      # A GitHub Actions runner carrying a label — the repo's enrolled
      # runner (the repo's name), or a pool named with `--runner` — reached
      # through dev's generic workflow (Lifecycle::LifecycleWorkflow): the
      # project's copy is dispatched on the snapshot branch with the verb as
      # its `verbs` input, the run that dispatch made is found by the
      # branch and watched to its verdict, and the artifact comes back as a
      # workflow artifact when the invocation asks (`--fetch`).
      class ActionsRunner
        extend T::Sig
        extend T::Helpers
        include Transport
        final!

        # The run ended without GitHub's success verdict; the message
        # carries the verb, the label and the run's page.
        class RemoteVerbFailedError < RuntimeError; end

        sig(:final) { override.returns(String) }
        attr_reader :runner

        sig(:final) { override.returns(String) }
        def destination = "on #{@runner}"

        # @param runner [String] the label the job demands beside `self-hosted`
        # @param runs [Lifecycle::WorkflowRuns] the forge's side of the dispatch
        # @param workflow [Lifecycle::LifecycleWorkflow] the project's copy of the generic workflow
        # @param out [IO, StringIO] where the run's page is named
        sig(:final) do
          params(runner: String, runs: Lifecycle::WorkflowRuns, workflow: Lifecycle::LifecycleWorkflow, out: T.any(IO, StringIO)).void
        end
        def initialize(runner:, runs:, workflow:, out: $stdout)
          @runner = runner
          @runs = runs
          @workflow = workflow
          @out = out
        end

        # @raise [Lifecycle::LifecycleWorkflow::WorkflowMissingError]
        sig(:final) { override.void }
        def assert_ready! = @workflow.assert_installed!

        # @raise [RemoteVerbFailedError]
        # @raise [Lifecycle::WorkflowRuns::RunNotListedError]
        # @raise [Lifecycle::WorkflowRuns::WatchLostError]
        # @raise [Lifecycle::Gh::CommandFailedError] the dispatch, the verdict or the download refused
        sig(:final) { override.params(invocation: Lifecycle::VerbInvocation, snapshot: Lifecycle::Snapshot).void }
        def run(invocation, snapshot:)
          workflow = Lifecycle::LifecycleWorkflow::FILE_NAME
          @runs.dispatch(workflow:, ref: snapshot.branch.name, inputs: @workflow.inputs(invocation, runner: @runner))
          run = @runs.locate(workflow:, branch: snapshot.branch)
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
      end

      # The project's own build container as the degenerate runner (K9):
      # reached by `docker exec` (ProjectContainer), the verb's words run by
      # the dev inside — `dev build <build>` — in the container's workspace
      # at the snapshot, which the container fetches from the forge with its
      # own gh auth. Watching is waiting: the exec's exit status is the
      # verdict. The artifact lands in the container's data root; when the
      # invocation asks (`--fetch`) it is copied out into the host's store —
      # unless the two are one (a Linux host's bind mount), where it already
      # is. Last in the resolution order and forced by `--container`
      # (DispatchResolver).
      class LocalContainer
        extend T::Sig
        extend T::Helpers
        include Transport
        final!

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
        def runner = ContainerWorkspace::RUNNER

        sig(:final) { override.returns(String) }
        def destination = @containers.destination(@image)

        # @raise [ProjectContainer::EngineUnavailableError]
        sig(:final) { override.void }
        def assert_ready! = @containers.assert_engine_up!

        # @raise [ContainerVerbFailedError]
        # @raise [EngineResourcesCheck::UndersizedEngineError]
        # @raise [ProjectContainer::RepoUnresolvedError]
        # @raise [BuildContainer::CopyOutFailedError] the fetch refused
        sig(:final) { override.params(invocation: Lifecycle::VerbInvocation, snapshot: Lifecycle::Snapshot).void }
        def run(invocation, snapshot:)
          status = @containers.run(@image, argv: ["dev", *invocation.words], snapshot:)
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

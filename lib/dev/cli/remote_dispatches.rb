# typed: strict
# frozen_string_literal: true

require "pathname"
require "stringio"
require "dev/environment_image"
require "dev/lifecycle"
require "dev/project_container"
require "dev/ui"
require_relative "dispatch"
require_relative "transport"

module Dev
  module Cli
    # Builds the remote dispatch for a host the resolver chose (dev#192,
    # K8): the wiring of a Dispatch::Remote — the sync step over the
    # project's checkout, the forge client, the project's copy of the
    # generic workflow, the UI the crossing line prints on — made once per
    # run at the composition root and handed to DispatchResolver, which
    # owns the decision and nothing of the construction. One method per
    # transport: `actions_runner` and `local_container` (dev#421).
    class RemoteDispatches
      extend T::Sig

      # @param root [Pathname] the project root
      # @param ui [Ui] where the crossing line prints
      # @param out [IO, StringIO] where the transport names the run
      # @param sync [Lifecycle::SnapshotSync] the sync step over the checkout
      # @param runs [Lifecycle::WorkflowRuns] the forge's side of a dispatch
      # @param workflow [Lifecycle::LifecycleWorkflow] the project's copy of the generic workflow
      # @param containers [ProjectContainer] the way into the project's containers
      sig do
        params(
          root: Pathname,
          ui: Ui,
          out: T.any(IO, StringIO),
          sync: Lifecycle::SnapshotSync,
          runs: Lifecycle::WorkflowRuns,
          workflow: Lifecycle::LifecycleWorkflow,
          containers: ProjectContainer,
        ).void
      end
      def initialize(
        root:,
        ui:,
        out: $stdout,
        sync: Lifecycle::SnapshotSync.new(root:),
        runs: Lifecycle::WorkflowRuns.new(gh: Lifecycle::Gh.new(root:)),
        workflow: Lifecycle::LifecycleWorkflow.new(root:),
        containers: ProjectContainer.new(project_root: root)
      )
        @ui = ui
        @out = out
        @sync = sync
        @runs = runs
        @workflow = workflow
        @containers = containers
      end

      # The remote dispatch to the Actions runners carrying a label.
      #
      # @param label [String] the repo's enrolled runner, a pool, or what `--runner` named
      # @return [Dispatch::Remote]
      sig { params(label: String).returns(Dispatch::Remote) }
      def actions_runner(label)
        Dispatch::Remote.new(
          transport: Transport::ActionsRunner.new(runner: label, runs: @runs, workflow: @workflow, out: @out),
          sync: @sync,
          ui: @ui,
        )
      end

      # The remote dispatch to the project's own container of an image.
      #
      # @param image [EnvironmentImage] the build's environment
      # @return [Dispatch::Remote]
      sig { params(image: EnvironmentImage).returns(Dispatch::Remote) }
      def local_container(image)
        Dispatch::Remote.new(
          transport: Transport::LocalContainer.new(image:, containers: @containers, out: @out),
          sync: @sync,
          ui: @ui,
        )
      end
    end
  end
end

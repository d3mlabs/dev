# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "shipped_workflow"
require_relative "verb_invocation"

module Dev
  module Lifecycle
    # The contract of the generic workflow dev ships
    # (`share/workflows/dev-lifecycle.yml`): the file name a project carries
    # it under and its three inputs, spelled once here. dev does not write
    # the file into the project; a dispatch that finds it missing refuses
    # with the copy named.
    class LifecycleWorkflow
      extend T::Sig

      # The project carries no copy of the workflow.
      class WorkflowMissingError < RuntimeError; end

      FILE_NAME = "dev-lifecycle.yml"

      VERBS_INPUT = "verbs"
      RUNNER_INPUT = "runner"
      FETCH_INPUT = "fetch"

      # @param root [Pathname] the project root
      sig { params(root: Pathname).void }
      def initialize(root:)
        @root = root
        @shipped = T.let(ShippedWorkflow.new(file_name: FILE_NAME, root:), ShippedWorkflow)
      end

      # @return [Pathname] the project's copy
      sig { returns(Pathname) }
      def path
        @shipped.path
      end

      # @return [Pathname] dev's own copy
      sig { returns(Pathname) }
      def source
        @shipped.source
      end

      # Refuse before anything leaves the machine when the project carries
      # no copy to dispatch.
      #
      # @return [void]
      # @raise [WorkflowMissingError]
      sig { void }
      def assert_installed!
        return if @shipped.installed?

        raise WorkflowMissingError,
          "#{@root} has no #{@shipped.project_path}: the remote dispatch runs dev's generic workflow from the project's checkout — " \
            "copy it in and commit it (#{@shipped.copy_instruction})"
      end

      # The dispatch's inputs for one invocation on one runner label.
      #
      # @param invocation [VerbInvocation]
      # @param runner [String] the label the job demands beside `self-hosted`
      # @return [Hash{String => String}] input name → value, as `gh workflow run -f` takes them
      sig { params(invocation: VerbInvocation, runner: String).returns(T::Hash[String, String]) }
      def inputs(invocation, runner:)
        { VERBS_INPUT => invocation.to_s, RUNNER_INPUT => runner, FETCH_INPUT => invocation.fetch.nil? ? "false" : "true" }
      end
    end
  end
end

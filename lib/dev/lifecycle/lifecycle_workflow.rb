# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "verb_invocation"

module Dev
  module Lifecycle
    # The contract of the generic workflow dev ships
    # (`share/workflows/dev-lifecycle.yml`; dev#192, K7): the one file name
    # a project carries it under — `gh workflow run` names a workflow by
    # file — and its three inputs, spelled once here and read by the
    # workflow. dev does not write the file into the project: a workflow
    # is the project's to review and commit, so a dispatch that finds it
    # missing refuses with the copy named, source path included.
    class LifecycleWorkflow
      extend T::Sig

      # The project carries no copy of the workflow.
      class WorkflowMissingError < RuntimeError; end

      FILE_NAME = "dev-lifecycle.yml"
      # Where a project carries it, relative to its root.
      PROJECT_PATH = T.let(Pathname(".github/workflows") / FILE_NAME, Pathname)
      # dev's own copy, relative to this file (lib/dev/lifecycle/ → the
      # repo or libexec root), the installed location under brew.
      SOURCE = T.let(
        Pathname(File.expand_path(File.join(T.must(__dir__), "..", "..", "..", "share", "workflows", FILE_NAME))),
        Pathname,
      )

      VERBS_INPUT = "verbs"
      RUNNER_INPUT = "runner"
      FETCH_INPUT = "fetch"

      # @param root [Pathname] the project root
      sig { params(root: Pathname).void }
      def initialize(root:)
        @root = root
      end

      # @return [Pathname] the project's copy
      sig { returns(Pathname) }
      def path
        @root / PROJECT_PATH
      end

      # Refuse before anything leaves the machine when the project carries
      # no copy to dispatch.
      #
      # @return [void]
      # @raise [WorkflowMissingError]
      sig { void }
      def assert_installed!
        return if path.file?

        raise WorkflowMissingError,
          "#{@root} has no #{PROJECT_PATH}: the remote dispatch runs dev's generic workflow from the project's checkout — " \
            "copy it in and commit it (mkdir -p #{PROJECT_PATH.dirname} && cp #{SOURCE} #{PROJECT_PATH})"
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

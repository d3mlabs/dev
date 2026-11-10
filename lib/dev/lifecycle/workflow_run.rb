# typed: strict
# frozen_string_literal: true

module Dev
  module Lifecycle
    # One run of the generic workflow as the forge lists it (dev#192, K7):
    # the id `gh run watch` and `gh run download` take, the page a person
    # opens, and GitHub's two-word verdict — `status` while it runs,
    # `conclusion` once it has. What the remote dispatch watches and
    # judges; nothing of the job's output lives here.
    class WorkflowRun < T::Struct
      extend T::Sig

      COMPLETED = "completed"
      SUCCESS = "success"

      const :id, Integer
      const :url, String
      # @return [String] GitHub's `status`: queued, in_progress, completed
      const :status, String
      # @return [String, nil] GitHub's `conclusion` once completed: success, failure, cancelled, …
      const :conclusion, T.nilable(String)

      # @return [Boolean]
      sig { returns(T::Boolean) }
      def completed?
        status == COMPLETED
      end

      # @return [Boolean] completed with GitHub's success verdict
      sig { returns(T::Boolean) }
      def succeeded?
        completed? && conclusion == SUCCESS
      end

      sig { params(other: Object).returns(T::Boolean) }
      def ==(other)
        other.is_a?(WorkflowRun) && id == other.id && url == other.url && status == other.status && conclusion == other.conclusion
      end

      sig { params(other: Object).returns(T::Boolean) }
      def eql?(other)
        self == other
      end

      sig { returns(Integer) }
      def hash
        [WorkflowRun, id, url, status, conclusion].hash
      end
    end
  end
end

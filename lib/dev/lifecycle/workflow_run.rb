# typed: strict
# frozen_string_literal: true

require_relative "../value_equality"

module Dev
  module Lifecycle
    # One run of the generic workflow as the forge lists it: the id `gh run
    # watch` and `gh run download` take, the page a person opens, and
    # GitHub's `status` while it runs and `conclusion` once it has.
    class WorkflowRun < T::Struct
      extend T::Sig
      include Dev::ValueEquality::Derived

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

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [id, url, status, conclusion]
      end
    end
  end
end

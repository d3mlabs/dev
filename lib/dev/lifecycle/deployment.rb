# typed: strict
# frozen_string_literal: true

require "time"
require_relative "deployment_record"
require_relative "../value_equality"

module Dev
  module Lifecycle
    # A DeploymentRecord as the forge holds it: the record, the GitHub
    # Deployment's id, when it was created, and the page it is visible on.
    class Deployment < T::Struct
      extend T::Sig
      include Dev::ValueEquality::Derived

      const :record, DeploymentRecord
      const :id, Integer
      const :created_at, Time
      const :url, String

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [record, id, created_at, url]
      end
    end
  end
end

# typed: strict
# frozen_string_literal: true

require "time"
require_relative "deployment_record"

module Dev
  module Lifecycle
    # A DeploymentRecord as the forge holds it (dev#192, K6): the record,
    # the GitHub Deployment's id, when it was created, and the page it is
    # visible on — the repo's deployments view for the channel, which is
    # what makes the ledger readable without dev at all.
    class Deployment < T::Struct
      extend T::Sig

      const :record, DeploymentRecord
      const :id, Integer
      const :created_at, Time
      const :url, String

      sig { params(other: Object).returns(T::Boolean) }
      def ==(other)
        other.is_a?(Deployment) && record == other.record && id == other.id && created_at == other.created_at && url == other.url
      end

      sig { params(other: Object).returns(T::Boolean) }
      def eql?(other) = self == other

      sig { returns(Integer) }
      def hash = [Deployment, record, id, created_at, url].hash
    end
  end
end

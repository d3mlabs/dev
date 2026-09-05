# typed: strict
# frozen_string_literal: true

module Dev
  module Deps
    # An outgoing dependency edge of a specific PackageVersion: "this version
    # requires that name, under this constraint".
    #
    # Edges are facts about a *version*, not about a chosen pin, which is why
    # they hang off PackageVersion. The constraint stays exactly as the backing
    # service reported it (a string like ">= 1.0", a hash, or nothing at all);
    # normalizing it into dev's constraint shape is the Resolver's job, since
    # only the Resolver knows the requirement vocabulary it will hand to the
    # integration's VersionScheme.
    class DependencyEdge
      extend T::Sig

      # @return [String] the required package's name, within the same universe
      sig { returns(String) }
      attr_reader :name

      # @return [Hash, String, nil] the raw constraint as reported upstream
      sig { returns(T.nilable(T.any(String, T::Hash[String, T.untyped]))) }
      attr_reader :constraint

      # @param name [String] the required package's name
      # @param constraint [Hash, String, nil] raw upstream constraint, or nil
      #   when the edge pins nothing
      sig do
        params(
          name: String,
          constraint: T.nilable(T.any(String, T::Hash[String, T.untyped])),
        ).void
      end
      def initialize(name:, constraint:)
        @name = name
        @constraint = constraint
        freeze
      end

      # @param other [Object]
      # @return [Boolean] whether other is the same edge
      sig { params(other: T.untyped).returns(T::Boolean) }
      def ==(other)
        return false unless other.is_a?(DependencyEdge)

        [name, constraint] == [other.name, other.constraint]
      end
      alias_method :eql?, :==

      # @return [Integer] hash code
      sig { returns(Integer) }
      def hash
        [self.class, name, constraint].hash
      end
    end
  end
end

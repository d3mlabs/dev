# typed: strict
# frozen_string_literal: true

require_relative "requirement"
require_relative "version_scheme"

module Dev
  module Deps
    # The scheme of every channel with a total order over its versions: the
    # requirement is evaluated as comparator terms (Requirement#bounds —
    # `~>` already expanded) against the channel's comparison key, and
    # versions sort by the same key. A subclass states the ordering alone:
    # `comparison_key` reads a coordinate into something `<=>`-comparable
    # and raises InvalidVersionError for what the ecosystem cannot read.
    # `coordinate` is the version string unless the channel orders a fact
    # instead (a git ref).
    #
    # A universe version the ordering cannot read satisfies nothing, `Any`
    # included: it cannot be placed, so it cannot be the max. A requirement
    # version the ordering cannot read is the declaration's fault
    # (InvalidRequirementError).
    class RangeScheme < VersionScheme
      extend T::Sig
      extend T::Helpers
      abstract!

      # @param version [PackageVersion] a candidate
      # @param requirement [Requirement]
      # @return [Boolean]
      # @raise [InvalidVersionError] if the candidate's coordinate does not parse
      # @raise [InvalidRequirementError] if a requirement version does not parse
      sig { override.overridable.params(version: PackageVersion, requirement: Requirement).returns(T::Boolean) }
      def satisfies?(version, requirement)
        key = comparison_key(coordinate(version))
        requirement.bounds.all? { |bound| holds?(key, bound) }
      end

      # @param versions [Array<PackageVersion>]
      # @return [Array<PackageVersion>] ascending by the channel's ordering
      # @raise [InvalidVersionError] if any coordinate does not parse
      sig { override.overridable.params(versions: T::Array[PackageVersion]).returns(T::Array[PackageVersion]) }
      def sort(versions)
        versions.sort_by { |version| comparison_key(coordinate(version)) }
      end

      protected

      # What the requirement is evaluated against: the version string, unless
      # the channel orders a version fact instead.
      #
      # @param version [PackageVersion]
      # @return [String]
      sig { overridable.params(version: PackageVersion).returns(String) }
      def coordinate(version)
        version.version
      end

      # The channel's reading of a coordinate as a comparable key.
      #
      # @param coordinate [String]
      # @return [Object] `<=>`-comparable with every other key of this channel
      # @raise [InvalidVersionError] if the channel cannot read it
      sig { abstract.params(coordinate: String).returns(T.untyped) }
      def comparison_key(coordinate); end

      private

      # @param key [Object] the candidate's comparison key
      # @param bound [Requirement::Bound] one comparator term
      # @return [Boolean]
      # @raise [InvalidRequirementError] if the bound's version does not parse
      sig { params(key: T.untyped, bound: Requirement::Bound).returns(T::Boolean) }
      def holds?(key, bound)
        comparison = T.let(key <=> bound_key(bound), Integer)
        case bound.operator
        when "=" then comparison.zero?
        when "!=" then !comparison.zero?
        when ">=" then comparison >= 0
        when ">" then comparison.positive?
        when "<=" then comparison <= 0
        else comparison.negative?
        end
      end

      # @param bound [Requirement::Bound]
      # @return [Object] the bound's version as this channel's key
      # @raise [InvalidRequirementError] if the channel cannot read the version
      sig { params(bound: Requirement::Bound).returns(T.untyped) }
      def bound_key(bound)
        comparison_key(bound.version)
      rescue InvalidVersionError => e
        raise InvalidRequirementError, "#{bound}: #{e.message}"
      end
    end
  end
end

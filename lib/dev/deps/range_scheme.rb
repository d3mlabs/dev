# typed: strict
# frozen_string_literal: true

require_relative "requirement"
require_relative "version_scheme"

module Dev
  module Deps
    # The scheme of every channel with a total order over its versions: the
    # requirement is evaluated as comparator terms (Requirement#bounds —
    # `^` and `~` already expanded) against the channel's comparison key,
    # and versions sort by the same key. A subclass states the ordering
    # alone: `comparison_key` reads a coordinate into something
    # `<=>`-comparable and raises InvalidVersionError for what the
    # ecosystem cannot read. `coordinate` is the version string unless the
    # channel orders a fact instead (a git ref).
    #
    # Prereleases are read as node-semver reads them: a version that
    # precedes a release is a candidate only where the requirement asked
    # for prereleases of that very release — a term whose version is a
    # prerelease of the same release (`>=1.0.0-0` admits `1.0.0-rc.1`; `^1`
    # admits neither `1.5.0-beta` nor `2.0.0-rc.1`; `Any` admits none). A
    # channel says what a prerelease is through `prerelease_base`; one
    # whose versions are all releases (brew's stable spec, a rock) leaves
    # the default, and the rule never fires.
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
        bounds = requirement.bounds
        bounds.all? { |bound| holds?(key, bound) } && admits_prerelease?(key, bounds)
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

      # The release a prerelease key precedes (`2.0.0` for `2.0.0-rc.1`),
      # as a key `==`-comparable with another release's; nil when the key
      # is itself a release. The default says the channel has no
      # prereleases.
      #
      # @param key [Object] a comparison key of this channel
      # @return [Object, nil]
      sig { overridable.params(key: T.untyped).returns(T.untyped) }
      def prerelease_base(key)
        nil
      end

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
        when ">=" then comparison >= 0
        when ">" then comparison.positive?
        when "<=" then comparison <= 0
        else comparison.negative?
        end
      end

      # node-semver's prerelease rule: a release is always admitted; a
      # prerelease only where some term names a prerelease of its release.
      #
      # @param key [Object] the candidate's comparison key
      # @param bounds [Array<Requirement::Bound>] the comparator terms
      # @return [Boolean]
      # @raise [InvalidRequirementError] if a bound's version does not parse
      sig { params(key: T.untyped, bounds: T::Array[Requirement::Bound]).returns(T::Boolean) }
      def admits_prerelease?(key, bounds)
        base = prerelease_base(key)
        return true if base.nil?

        bounds.any? { |bound| prerelease_base(bound_key(bound)) == base }
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

# typed: strict
# frozen_string_literal: true

require "dev/lifecycle/series"
require_relative "range_scheme"
require_relative "series_span"

module Dev
  module Deps
    # Tag semantics (:gh): the universe's versions are release and tag
    # names. An exact ask names a tag as spelled (`tag: "5.6.1-css-83"`,
    # `tag: "toolchain-2"`) and matches it by name; a range reads the tags
    # that are versions — a leading `v` dropped (`v3.11.3` is 3.11.3) and
    # Gem::Version's tolerant ordering over the rest — and the tags that
    # are not (`latest`, `toolchain-2`) are simply not candidates for it.
    # A range whose bounds are series boundaries (`~> 1`, `>= 1, < 2`,
    # `>= 1`) is series-shaped, and says which series it covers.
    class TagScheme < RangeScheme
      extend T::Sig

      # The tag is not a version the ordering can read.
      class InvalidVersionError < VersionScheme::InvalidVersionError; end

      # A `v` (or `V`) directly before the first digit: `v1.2.3`, `V2`.
      VERSION_PREFIX = /\Av(?=\d)/i

      # @param version [PackageVersion] a candidate; its version is the tag
      # @param requirement [Requirement]
      # @return [Boolean] for Exact, whether the tag is the one named (the
      #   `v` prefix aside); for a range, the ordering's verdict
      # @raise [InvalidVersionError] if a range is evaluated over a tag that is no version
      sig { override.params(version: PackageVersion, requirement: Requirement).returns(T::Boolean) }
      def satisfies?(version, requirement)
        return unprefixed(coordinate(version)) == unprefixed(requirement.version) if requirement.is_a?(Requirement::Exact)

        super
      end

      # Tags that are versions order by version; the tags that are not (an
      # exact `branch: "main"` or `tag: "toolchain-2"` is a candidate too)
      # sit below them, in the universe's reported order.
      #
      # @param versions [Array<PackageVersion>]
      # @return [Array<PackageVersion>] ascending
      sig { override.params(versions: T::Array[PackageVersion]).returns(T::Array[PackageVersion]) }
      def sort(versions)
        unordered, ordered = versions.partition { |version| version_key(version).nil? }
        unordered + ordered.sort_by { |version| T.must(version_key(version)) }
      end

      # The whole series a requirement covers: one `>=` at a series floor
      # (`1`, `1.0`, `1.0.0` — a major and nothing finer), at most one `<`
      # at a floor above it, and no other term. `Any` covers every series.
      # An exact ask, or any bound inside a series (`>= 1.4`, `~> 1.2`,
      # `!= 1.1`), names versions and has no span.
      #
      # @param requirement [Requirement]
      # @return [SeriesSpan, nil]
      # @raise [InvalidRequirementError] if a bound's version is no version tag
      sig { override.params(requirement: Requirement).returns(T.nilable(SeriesSpan)) }
      def series_span(requirement)
        return SeriesSpan.new(from: Lifecycle::Series.new(0)) if requirement.any?
        return nil if requirement.is_a?(Requirement::Exact)

        bounds = requirement.bounds
        lower = bounds.select { |bound| bound.operator == ">=" }
        upper = bounds.select { |bound| bound.operator == "<" }
        return nil unless lower.size == 1 && upper.size <= 1 && lower.size + upper.size == bounds.size

        from = series_floor(T.must(lower.first))
        to = upper.first&.then { |bound| series_floor(bound) }
        return nil if from.nil? || (upper.any? && to.nil?) || (to && to.major <= from.major)

        SeriesSpan.new(from:, to:)
      end

      protected

      # @param coordinate [String] a tag
      # @return [Gem::Version]
      # @raise [InvalidVersionError] if the tag is no version (Gem::Version
      #   reads the empty string as 0, so digit-led is checked first)
      sig { override.params(coordinate: String).returns(Gem::Version) }
      def comparison_key(coordinate)
        version = unprefixed(coordinate)
        raise InvalidVersionError, "not a version tag: #{coordinate.inspect}" unless version.match?(/\A\d/)

        Gem::Version.new(version)
      rescue ArgumentError
        raise InvalidVersionError, "not a version tag: #{coordinate.inspect}"
      end

      # A tag with a letter in it precedes its release as rubygems reads
      # it (`v2.0.0-rc.1` precedes `2.0.0`), so `^1` never picks a
      # release candidate of 2.0.0 and `Any` never picks one at all.
      #
      # @param key [Gem::Version]
      # @return [Gem::Version, nil] the release a prerelease precedes
      sig { override.params(key: Gem::Version).returns(T.nilable(Gem::Version)) }
      def prerelease_base(key)
        key.release if key.prerelease?
      end

      private

      # The series whose floor a bound sits on: its version is a major and
      # nothing finer (`1`, `1.0.0`), not a pre-release.
      #
      # @param bound [Requirement::Bound]
      # @return [Lifecycle::Series, nil] nil when the bound is inside a series
      # @raise [InvalidRequirementError] if the bound's version is no version tag
      sig { params(bound: Requirement::Bound).returns(T.nilable(Lifecycle::Series)) }
      def series_floor(bound)
        key = T.let(bound_key(bound), Gem::Version)
        return nil if key.prerelease?

        segments = key.canonical_segments
        return nil unless segments.size == 1

        Lifecycle::Series.new(T.cast(segments.fetch(0), Integer))
      end

      # @param version [PackageVersion]
      # @return [Gem::Version, nil] the tag's key, or nil when the tag is no version
      sig { params(version: PackageVersion).returns(T.nilable(Gem::Version)) }
      def version_key(version)
        comparison_key(coordinate(version))
      rescue InvalidVersionError
        nil
      end

      # @param tag [String]
      # @return [String] the tag without its version prefix
      sig { params(tag: String).returns(String) }
      def unprefixed(tag)
        tag.sub(VERSION_PREFIX, "")
      end
    end
  end
end

# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module Dev
  module Deps
    # A semver.org version — `MAJOR.MINOR.PATCH[-prerelease][+build]` —
    # ordered by the standard's precedence (§11): the numeric segments,
    # then a prerelease below its release, its identifiers compared
    # numeric-below-alphanumeric; build metadata is carried and never
    # compared.
    #
    # A version may be partial (`1`, `1.2`): that is the shape a range
    # shorthand is written over (`^1`, `~1.2`) and a comparator may name
    # (`>= 1.2`), the segments not written reading as zero. `segments` keeps
    # what was written, for the shorthand whose upper bound depends on it.
    class SemverVersion
      extend T::Sig
      include Comparable

      # The string is not a semver version, partial or whole.
      class InvalidVersionError < StandardError; end

      PATTERN = /\A(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?\z/

      # @return [Integer]
      sig { returns(Integer) }
      attr_reader :major

      # @return [Integer, nil] nil when the version was written without one
      sig { returns(T.nilable(Integer)) }
      attr_reader :minor

      # @return [Integer, nil] nil when the version was written without one
      sig { returns(T.nilable(Integer)) }
      attr_reader :patch

      # @return [Array<String>] the dot-separated prerelease identifiers; empty for a release
      sig { returns(T::Array[String]) }
      attr_reader :prerelease

      # @return [String, nil] the build metadata, when written
      sig { returns(T.nilable(String)) }
      attr_reader :build

      # @param major [Integer]
      # @param minor [Integer, nil]
      # @param patch [Integer, nil]
      # @param prerelease [Array<String>]
      # @param build [String, nil]
      sig do
        params(
          major: Integer,
          minor: T.nilable(Integer),
          patch: T.nilable(Integer),
          prerelease: T::Array[String],
          build: T.nilable(String),
        ).void
      end
      def initialize(major:, minor: nil, patch: nil, prerelease: [], build: nil)
        @major = major
        @minor = minor
        @patch = patch
        @prerelease = T.let(prerelease.dup.freeze, T::Array[String])
        @build = build
        freeze
      end

      # @return [Array<Integer>] the segments as written: `1.2` is `[1, 2]`
      sig { returns(T::Array[Integer]) }
      def segments
        [major, minor, patch].compact
      end

      # @return [Boolean] whether the version precedes a release
      sig { returns(T::Boolean) }
      def prerelease?
        !prerelease.empty?
      end

      # The release this version is, or precedes: every segment written,
      # no prerelease, no build (`1.2` → `1.2.0`, `2.0.0-rc.1` → `2.0.0`).
      #
      # @return [SemverVersion]
      sig { returns(SemverVersion) }
      def release
        SemverVersion.new(major: major, minor: minor || 0, patch: patch || 0)
      end

      # The version with every segment written, the prerelease kept and
      # the build dropped (`1.2-beta.1` → `1.2.0-beta.1`): what a range
      # shorthand's lower bound is.
      #
      # @return [SemverVersion]
      sig { returns(SemverVersion) }
      def padded
        SemverVersion.new(major: major, minor: minor || 0, patch: patch || 0, prerelease: prerelease)
      end

      # The next release at one written segment: that segment one higher,
      # every segment after it zero, three segments written (`1.2.3` at 0
      # → `2.0.0`, `0.2` at 1 → `0.3.0`). What a range shorthand's upper
      # bound is.
      #
      # @param index [Integer] 0 for the major, 1 the minor, 2 the patch
      # @return [SemverVersion]
      # @raise [IndexError] if no segment was written at index
      sig { params(index: Integer).returns(SemverVersion) }
      def bump(index)
        triple = [0, 0, 0].each_with_index.map { |zero, position| position < index ? segments.fetch(position) : zero }
        triple[index] = segments.fetch(index) + 1
        SemverVersion.new(major: T.must(triple[0]), minor: triple[1], patch: triple[2])
      end

      # @return [String] as written
      sig { returns(String) }
      def to_s
        core = segments.join(".")
        core += "-#{prerelease.join(".")}" if prerelease?
        core += "+#{build}" if build
        core
      end

      # Precedence (§11): numeric segments, then a release above any of
      # its prereleases, then identifier by identifier — numeric below
      # alphanumeric, numerics by value, alphanumerics as text, a shorter
      # list below a longer one that it prefixes.
      #
      # @param other [Object]
      # @return [Integer, nil] nil for anything but a SemverVersion
      sig { params(other: T.anything).returns(T.nilable(Integer)) }
      def <=>(other)
        return nil unless other.is_a?(SemverVersion)

        by_release = T.must(release_key <=> other.release_key)
        return by_release unless by_release.zero?
        return 0 if !prerelease? && !other.prerelease?
        return 1 if !prerelease?
        return -1 if !other.prerelease?

        T.must(prerelease_key <=> other.prerelease_key)
      end

      class << self
        extend T::Sig

        # @param string [String] `1`, `1.2`, `1.2.3`, `1.2.3-rc.1+build.5`
        # @return [SemverVersion]
        # @raise [InvalidVersionError] if the string is not a semver version
        sig { params(string: String).returns(SemverVersion) }
        def parse(string)
          match = PATTERN.match(string)
          raise InvalidVersionError, "not a semver version: #{string.inspect}" unless match

          new(
            major: T.must(match[1]).to_i,
            minor: match[2]&.to_i,
            patch: match[3]&.to_i,
            prerelease: match[4].to_s.split("."),
            build: match[5],
          )
        end
      end

      protected

      # @return [Array<Integer>] the numeric segments, the unwritten ones as zero
      sig { returns(T::Array[Integer]) }
      def release_key
        [major, minor || 0, patch || 0]
      end

      # Each identifier as a sortable triple: numerics first (0, value),
      # alphanumerics after (1, text).
      #
      # @return [Array<Array>]
      sig { returns(T::Array[T::Array[T.any(Integer, String)]]) }
      def prerelease_key
        prerelease.map do |identifier|
          identifier.match?(/\A\d+\z/) ? [0, identifier.to_i, ""] : [1, 0, identifier]
        end
      end
    end
  end
end

# typed: strict
# frozen_string_literal: true

require_relative "range_scheme"

module Dev
  module Deps
    # Tag semantics (:gh): the universe's versions are release and tag
    # names. An exact ask names a tag as spelled (`tag: "5.6.1-css-83"`,
    # `tag: "toolchain-2"`) and matches it by name; a range reads the tags
    # that are versions — a leading `v` dropped (`v3.11.3` is 3.11.3) and
    # Gem::Version's tolerant ordering over the rest — and the tags that
    # are not (`latest`, `toolchain-2`) are simply not candidates for it.
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

      private

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

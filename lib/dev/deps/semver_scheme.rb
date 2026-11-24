# typed: strict
# frozen_string_literal: true

require_relative "range_scheme"
require_relative "semver_version"

module Dev
  module Deps
    # Semantic-versioning ordering (:ficsit): dev's requirement evaluated
    # over MAJOR.MINOR.PATCH[-prerelease][+build] versions with semver.org's
    # precedence (SemverVersion): prereleases below their release
    # ("1.0.0-rc.1" < "1.0.0"), identifiers numeric-below-alphanumeric,
    # build metadata ignored. A requirement may name a partial version
    # (`>=1.2`): missing segments read as zero.
    class SemverScheme < RangeScheme
      extend T::Sig

      # The version string is not a semver version.
      class InvalidVersionError < VersionScheme::InvalidVersionError; end

      protected

      # @param coordinate [String]
      # @return [SemverVersion]
      # @raise [InvalidVersionError] if the version does not parse
      sig { override.params(coordinate: String).returns(SemverVersion) }
      def comparison_key(coordinate)
        SemverVersion.parse(coordinate)
      rescue SemverVersion::InvalidVersionError => e
        raise InvalidVersionError, e.message
      end

      # @param key [SemverVersion]
      # @return [SemverVersion, nil] the release a prerelease precedes
      sig { override.params(key: SemverVersion).returns(T.nilable(SemverVersion)) }
      def prerelease_base(key)
        key.release if key.prerelease?
      end
    end
  end
end

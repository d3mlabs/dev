# typed: strict
# frozen_string_literal: true

require_relative "range_scheme"

module Dev
  module Deps
    # Semantic-versioning ordering (:ficsit): dev's requirement evaluated
    # over MAJOR.MINOR.PATCH[-prerelease][+build] versions. Prereleases
    # order below their release ("1.0.0-rc.1" < "1.0.0"), with semver's
    # numeric-below-alphanumeric identifier ordering; build metadata is
    # ignored. A requirement may name a partial version (`>= 1.2`): missing
    # segments read as zero.
    #
    # ficsit.app writes its own constraints in node-style range syntax
    # (`^3.12.0`); SemverRange translates that into dev's language at the
    # boundary, so this scheme never sees a caret.
    class SemverScheme < RangeScheme
      extend T::Sig

      # The version string is not a semver version.
      class InvalidVersionError < VersionScheme::InvalidVersionError; end

      # Up to three release segments, optional -prerelease, ignored +build.
      VERSION_PATTERN = /\A(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?\z/

      protected

      # Semver comparison key: [major, minor, patch, release-flag, prerelease
      # identifiers]. The release flag puts releases (1) above prereleases (0);
      # prerelease identifiers compare numeric-below-alphanumeric per semver §11.
      #
      # @param coordinate [String]
      # @return [Array]
      # @raise [InvalidVersionError] if the version does not parse
      sig { override.params(coordinate: String).returns(T::Array[T.untyped]) }
      def comparison_key(coordinate)
        match = VERSION_PATTERN.match(coordinate)
        raise InvalidVersionError, "not a semver version: #{coordinate.inspect}" unless match

        prerelease = match[4]
        identifiers = prerelease.to_s.split(".").map do |identifier|
          identifier.match?(/\A\d+\z/) ? [0, identifier.to_i, ""] : [1, 0, identifier]
        end
        [match[1].to_i, match[2].to_i, match[3].to_i, prerelease ? 0 : 1, identifiers]
      end
    end
  end
end

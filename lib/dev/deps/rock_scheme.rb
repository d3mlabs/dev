# typed: strict
# frozen_string_literal: true

require_relative "range_scheme"

module Dev
  module Deps
    # LuaRocks ordering (:luarocks): dotted numeric versions with a
    # dash-separated rockspec revision ("3.4-1").
    #
    # NOT semver: the "-1" is a packaging revision that releases *above* its
    # unrevised version (3.4-1 > 3.4), where semver would read it as a
    # prerelease below it. That grammar difference is why luarocks gets its
    # own ordering instead of riding SemverScheme. dev's `~>` is rockspec's
    # (rubygems-style): `~> 1.0.5` is `>= 1.0.5, < 1.1`.
    class RockScheme < RangeScheme
      extend T::Sig

      # The version string is not a luarocks version.
      class InvalidVersionError < VersionScheme::InvalidVersionError; end

      # Dotted numeric segments with an optional numeric -revision.
      VERSION_PATTERN = /\A(\d+(?:\.\d+)*)(?:-(\d+))?\z/

      protected

      # Comparison key: [release segments (trailing zeros stripped), revision].
      #
      # @param coordinate [String]
      # @return [Array]
      # @raise [InvalidVersionError] if the version does not parse
      sig { override.params(coordinate: String).returns(T::Array[T.untyped]) }
      def comparison_key(coordinate)
        match = VERSION_PATTERN.match(coordinate)
        raise InvalidVersionError, "not a luarocks version: #{coordinate.inspect}" unless match

        segments = T.must(match[1]).split(".").map(&:to_i)
        segments.pop while segments.size > 1 && segments.last.to_i.zero?
        [segments, match[2].to_i]
      end
    end
  end
end

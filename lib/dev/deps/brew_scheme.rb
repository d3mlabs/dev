# typed: strict
# frozen_string_literal: true

require_relative "brew_version"
require_relative "range_scheme"

module Dev
  module Deps
    # Homebrew ordering (:brew, :python): dev's requirement evaluated over
    # the formula family's real stable versions — the bare spec's and its
    # versioned siblings' (llvm 21.1.0, llvm@19 19.1.7, llvm@18 18.1.8), as
    # BrewRepository enumerates them. The `@18` suffix is not a version:
    # the DSL reads `brew "llvm@18"` and `version: "18"` as `~> 18.0`, and
    # that is what 18.1.8 is matched against.
    #
    # Brew versions are tolerant of shape — `3.11.4_1` (a bottle revision,
    # above 3.11.4), `2024-01-15`, `1.0r3`, `1.0.0-beta` — and order by
    # Homebrew's own token rules (BrewVersion), which place revisions above
    # their base and prereleases below theirs; a version brew cannot read
    # (one not starting with a digit) is not a candidate.
    #
    # A family with one version has no range to pick among: it satisfies
    # `Any` (follow brew) or its exact version, and a range over it is
    # refused naming that version, rather than satisfied today and
    # unanswerable the day brew moves the formula.
    class BrewScheme < RangeScheme
      extend T::Sig

      # The version string is not one brew's ordering can read.
      class InvalidVersionError < VersionScheme::InvalidVersionError; end

      # @param name [String] the declaration's name
      # @param requirement [Requirement]
      # @param versions [Array<PackageVersion>] the family as reported
      # @return [String, nil] the refusal for a range over a one-version family
      sig do
        override.params(
          name: String,
          requirement: Requirement,
          versions: T::Array[PackageVersion],
        ).returns(T.nilable(String))
      end
      def refusal(name:, requirement:, versions:)
        return nil if versions.size != 1 || requirement.any? || requirement.is_a?(Requirement::Exact)

        only = T.must(versions.first).version
        "#{name}: brew has one version of it, #{only}, and a range (`#{requirement}`) cannot pick among one — " \
          "declare `brew \"#{name}\"` to follow brew, or `brew \"#{name}\", \"= #{only}\"` to hold it"
      end

      protected

      # @param coordinate [String] a brew stable version
      # @return [BrewVersion]
      # @raise [InvalidVersionError] if brew's ordering cannot read it
      sig { override.params(coordinate: String).returns(BrewVersion) }
      def comparison_key(coordinate)
        BrewVersion.new(coordinate)
      rescue BrewVersion::InvalidVersionError => e
        raise InvalidVersionError, e.message
      end
    end
  end
end

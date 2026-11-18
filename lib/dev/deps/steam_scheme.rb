# typed: strict
# frozen_string_literal: true

require_relative "version_scheme"

module Dev
  module Deps
    # Steam semantics (:steam): the universe is one branch's current
    # buildid (SteamRepository enumerates the tip of the branch the source
    # coordinate names), so the only asks it can answer are `Any` — the
    # tip — and an exact buildid, an assertion that the tip is still the
    # one pinned. A range has nothing to range over: Steam publishes no
    # build history, so it is refused until a source exists (dev#631).
    #
    # A pinned buildid that is no longer the branch tip fails resolution
    # loudly: Steam serves only current builds, so a stale pin cannot be
    # honored and pretending otherwise would defer the failure to install.
    class SteamScheme < VersionScheme
      extend T::Sig

      # @param requirement [Requirement]
      # @return [Boolean] Any or Exact
      sig { override.params(requirement: Requirement).returns(T::Boolean) }
      def supports?(requirement)
        requirement.any? || requirement.is_a?(Requirement::Exact)
      end

      # @return [String]
      sig { override.returns(String) }
      def supported
        "no requirement (the branch tip) or an exact buildid: Steam serves only branch tips, so there is no range to pick over"
      end

      # @param version [PackageVersion] a candidate (version is the buildid)
      # @param requirement [Requirement] Any, or the Exact buildid asserted
      # @return [Boolean]
      sig { override.params(version: PackageVersion, requirement: Requirement).returns(T::Boolean) }
      def satisfies?(version, requirement)
        return true if requirement.any?

        requirement.is_a?(Requirement::Exact) && requirement.version == version.version
      end

      # @param versions [Array<PackageVersion>] buildids
      # @return [Array<PackageVersion>] ascending numerically — buildids are
      #   monotonically increasing integers
      sig { override.params(versions: T::Array[PackageVersion]).returns(T::Array[PackageVersion]) }
      def sort(versions)
        versions.sort_by { |version| version.version.to_i }
      end

      # The way a Steam requirement goes unsatisfied, named with the universe
      # fact that decides it: the pinned buildid is no longer the branch's
      # tip. A version count would say nothing here — the universe is
      # always the one tip — so this replaces the generic message.
      #
      # @param name [String] the declaration's name
      # @param requirement [Requirement] the Exact buildid
      # @param versions [Array<PackageVersion>] the branch tip, buildid as
      #   version and "branch" in metadata
      # @return [String, nil] nil for an empty universe, which the generic message covers
      sig do
        override.params(
          name: String,
          requirement: Requirement,
          versions: T::Array[PackageVersion],
        ).returns(T.nilable(String))
      end
      def unsatisfied(name:, requirement:, versions:)
        tip = versions.first
        return nil if tip.nil? || !requirement.is_a?(Requirement::Exact)

        "#{name}: buildid #{requirement.version} is no longer the tip " \
          "of `#{tip.metadata["branch"]}` (now #{tip.version}); " \
          "Steam serves only branch tips — bump `buildid:` to it, or drop `buildid:` to follow the branch"
      end
    end
  end
end

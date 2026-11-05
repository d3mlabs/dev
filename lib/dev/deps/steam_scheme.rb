# typed: strict
# frozen_string_literal: true

require_relative "version_scheme"

module Dev
  module Deps
    # Steam constraint semantics (:steam): the universe is one buildid per
    # branch (SteamRepository enumerates every branch's tip), and the
    # constraint selects by branch — a fact match, not a version-string
    # match — plus an optional exact "buildid" assertion.
    #
    # A pinned buildid that is no longer the branch tip fails resolution
    # loudly: Steam serves only current builds, so a stale pin cannot be
    # honored and pretending otherwise would defer the failure to install.
    # The branch tips are enumerable in one query, so a constraint always
    # selects out of the reported universe.
    class SteamScheme < VersionScheme
      extend T::Sig

      # Branch selected when the declaration names none.
      DEFAULT_BRANCH = "public"

      # @param version [PackageVersion] a candidate (version is the buildid,
      #   "branch" rides its metadata)
      # @param constraint [Hash] declaration constraint; "branch" and
      #   optionally "buildid"
      # @return [Boolean]
      sig { override.params(version: PackageVersion, constraint: T::Hash[String, T.untyped]).returns(T::Boolean) }
      def satisfies?(version, constraint)
        branch = (constraint["branch"] || DEFAULT_BRANCH).to_s
        return false unless version.metadata["branch"].to_s == branch

        buildid = constraint["buildid"]
        buildid.nil? || buildid.to_s == version.version
      end

      # @param versions [Array<String>] buildids
      # @return [Array<String>] ascending numerically — buildids are
      #   monotonically increasing integers
      sig { override.params(versions: T::Array[String]).returns(T::Array[String]) }
      def sort(versions)
        versions.sort_by(&:to_i)
      end

      # The two ways a Steam constraint goes unsatisfied, each named with
      # the universe fact that decides it: the branch is not one the app
      # publishes, or the pinned buildid is no longer that branch's tip.
      # A version count would say nothing here — the universe is always
      # one buildid per branch — so this replaces the generic message.
      #
      # @param name [String] the declaration's name
      # @param constraint [Hash] "branch" (default public), optional "buildid"
      # @param versions [Array<PackageVersion>] one per branch, buildid as
      #   version and "branch" in metadata
      # @return [String]
      sig do
        override.params(
          name: String,
          constraint: T::Hash[String, T.untyped],
          versions: T::Array[PackageVersion],
        ).returns(String)
      end
      def unsatisfied(name:, constraint:, versions:)
        branch = (constraint["branch"] || DEFAULT_BRANCH).to_s
        tip = versions.find { |version| version.metadata["branch"].to_s == branch }
        if tip.nil?
          branches = versions.sort_by { |version| version.metadata["branch"].to_s }
            .map { |version| "#{version.metadata["branch"]} #{version.version}" }
          return "#{name}: Steam publishes no `#{branch}` branch (branches: #{branches.join(", ")})"
        end

        "#{name}: buildid #{constraint["buildid"]} is no longer the tip of `#{branch}` (now #{tip.version}); " \
          "Steam serves only branch tips — bump `buildid:` to it, or drop `buildid:` to follow the branch"
      end
    end
  end
end

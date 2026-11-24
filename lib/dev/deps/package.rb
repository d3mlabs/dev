# typed: strict
# frozen_string_literal: true

require_relative "package_id"
require_relative "package_version"
require_relative "series_head"

module Dev
  module Deps
    # A package and the versions its backing service currently offers — the
    # aggregate a Repository returns from #find — and, where the service
    # keeps per-series pointers (a gh repo's `v1` tag), the head each
    # pointer names.
    #
    # Deliberately has no #satisfies?, #sort or #best_match. A Package states
    # what exists; evaluating a requirement against a version is the
    # integration's VersionScheme, and choosing among the satisfying versions
    # is the Resolver's policy. Keeping all three apart is what lets a new
    # ecosystem supply facts without also supplying selection logic, and lets
    # dev change selection policy without touching any repository. See
    # docs/deps-architecture.md.
    #
    # The versions are exposed through this aggregate rather than returned as a
    # bare array so the universe always arrives with the identity it belongs to.
    class Package
      extend T::Sig

      # @return [PackageId] the identity these versions belong to
      sig { returns(PackageId) }
      attr_reader :id

      # @return [Array<PackageVersion>] available versions, in the order the
      #   repository reported them (no ordering promise: ordering is the
      #   VersionScheme's job)
      sig { returns(T::Array[PackageVersion]) }
      attr_reader :versions

      # @return [Array<SeriesHead>] the head of every series the service
      #   keeps a pointer for; empty when it keeps none (a derived channel)
      sig { returns(T::Array[SeriesHead]) }
      attr_reader :heads

      # @param id [PackageId] the package's identity
      # @param versions [Array<PackageVersion>] the available versions
      # @param heads [Array<SeriesHead>] the per-series heads, each naming one of the versions
      sig { params(id: PackageId, versions: T::Array[PackageVersion], heads: T::Array[SeriesHead]).void }
      def initialize(id:, versions:, heads: [])
        @id = id
        @versions = T.let(versions.dup.freeze, T::Array[PackageVersion])
        @heads = T.let(heads.dup.freeze, T::Array[SeriesHead])
        freeze
      end

      # Look up one version by its exact version string.
      #
      # @param version [String] the version string to match exactly
      # @return [PackageVersion, nil] the matching version, or nil if this
      #   package does not offer it
      sig { params(version: String).returns(T.nilable(PackageVersion)) }
      def version(version)
        versions.find { |candidate| candidate.version == version }
      end

      # @return [Boolean] whether the backing service offers no versions at all
      sig { returns(T::Boolean) }
      def empty?
        versions.empty?
      end
    end
  end
end

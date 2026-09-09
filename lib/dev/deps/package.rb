# typed: strict
# frozen_string_literal: true

require_relative "package_id"
require_relative "package_version"

module Dev
  module Deps
    # A package and the versions its backing service currently offers — the
    # aggregate a Repository returns from #find.
    #
    # Deliberately has no #satisfies?, #sort or #best_match. A Package states
    # what exists; evaluating a constraint against a version is the
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

      # @param id [PackageId] the package's identity
      # @param versions [Array<PackageVersion>] the available versions
      sig { params(id: PackageId, versions: T::Array[PackageVersion]).void }
      def initialize(id:, versions:)
        @id = id
        @versions = T.let(versions.dup.freeze, T::Array[PackageVersion])
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

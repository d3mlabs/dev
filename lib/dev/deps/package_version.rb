# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "artifact"
require_relative "dependency_edge"

module Dev
  module Deps
    # One available version of a package, and the facts the backing service
    # reports about it.
    #
    # Facts only: a PackageVersion never decides whether it satisfies anything
    # (that is the integration's VersionScheme) and never decides whether it is
    # the one to install (that is the Resolver). It is the unit of the universe
    # a Repository reports; the Resolver turns the chosen one into a Dependency
    # pin.
    #
    # Every optional fact is modeled as its empty form rather than nil, because
    # absence here is genuine absence: a version with no platforms has one
    # default target, a version with no artifacts is fetched by its own tool,
    # and a version with no edges requires nothing. See
    # docs/deps-architecture.md.
    class PackageVersion
      extend T::Sig

      # @return [String] the version string, in the ecosystem's own vocabulary
      #   (semver, gem version, tag, commit SHA, Steam buildid)
      sig { returns(String) }
      attr_reader :version

      # @return [Array<String>] targets this version publishes; empty means the
      #   version has a single default artifact
      sig { returns(T::Array[String]) }
      attr_reader :platforms

      # @return [String, nil] integrity digest for bytes the *tool* fetches
      #   (e.g. bundler's CHECKSUMS). Recorded for audit and drift detection;
      #   enforcement belongs to the tool. nil means the ecosystem publishes
      #   none.
      sig { returns(T.nilable(String)) }
      attr_reader :digest

      # @return [Hash{String => Artifact}] bytes dev can fetch, keyed by
      #   platform; empty for tool-mediated ecosystems
      sig { returns(T::Hash[String, Artifact]) }
      attr_reader :artifacts

      # @return [Array<DependencyEdge>] what this version requires
      sig { returns(T::Array[DependencyEdge]) }
      attr_reader :dependencies

      # @return [Hash{String => Object}] ecosystem-specific facts the
      #   integration needs at install time (this becomes the minted pin's
      #   metadata, before the Resolver stamps host/env)
      sig { returns(T::Hash[String, T.untyped]) }
      attr_reader :metadata

      # @param version [String] the version string
      # @param platforms [Array<String>] published targets
      # @param digest [String, nil] tool-fetched integrity digest, if published
      # @param artifacts [Hash{String => Artifact}] dev-fetchable bytes by platform
      # @param dependencies [Array<DependencyEdge>] outgoing edges
      # @param metadata [Hash{String => Object}] ecosystem-specific install facts
      sig do
        params(
          version: String,
          platforms: T::Array[String],
          digest: T.nilable(String),
          artifacts: T::Hash[String, Artifact],
          dependencies: T::Array[DependencyEdge],
          metadata: T::Hash[String, T.untyped],
        ).void
      end
      def initialize(version:, platforms: [], digest: nil, artifacts: {}, dependencies: [], metadata: {})
        @version = version
        @platforms = T.let(platforms.dup.freeze, T::Array[String])
        @digest = digest
        @artifacts = T.let(artifacts.dup.freeze, T::Hash[String, Artifact])
        @dependencies = T.let(dependencies.dup.freeze, T::Array[DependencyEdge])
        @metadata = T.let(metadata.dup.freeze, T::Hash[String, T.untyped])
        freeze
      end

      # @param other [Object]
      # @return [Boolean] whether other reports the same facts
      sig { params(other: T.untyped).returns(T::Boolean) }
      def ==(other)
        return false unless other.is_a?(PackageVersion)

        [version, platforms, digest, artifacts, dependencies, metadata] ==
          [other.version, other.platforms, other.digest, other.artifacts,
           other.dependencies, other.metadata]
      end
      alias_method :eql?, :==

      # @return [Integer] hash code
      sig { returns(Integer) }
      def hash
        [self.class, version, platforms, digest, artifacts, dependencies, metadata].hash
      end
    end
  end
end

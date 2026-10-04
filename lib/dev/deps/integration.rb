# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "artifact_store"
require_relative "dependency"
require_relative "repository"

module Dev
  module Deps
    # Lifecycle handler for a dependency type.
    #
    # Accepts a Repository and an ArtifactStore via DI at construction.
    # Receives all dependencies for its type at once via install_all —
    # handles per-dep install plus any batch artifacts (e.g. deps.cmake).
    class Integration
      extend T::Sig

      # Aggregate of per-dep failures within one install_all call: the loop
      # attempts every dep (one bad formula must not block an unrelated
      # engine download), collects what failed, and raises this at the end
      # so the run still fails loudly. The Installer flattens the failures
      # into its cross-integration report.
      class PartialInstallError < StandardError
        extend T::Sig

        # @return [Array<[String, StandardError]>] failed dep name → its error
        sig { returns(T::Array[[String, StandardError]]) }
        attr_reader :failures

        # @param failures [Array<[String, StandardError]>]
        sig { params(failures: T::Array[[String, StandardError]]).void }
        def initialize(failures)
          @failures = failures
          lines = failures.map { |name, error| "  #{name}: #{error.message}" }
          super("#{failures.size} dep install(s) failed:\n#{lines.join("\n")}")
        end
      end

      # @param repository [Repository, nil] source adapter for this integration type
      # @param store      [ArtifactStore, nil] where installed trees and downloaded blobs live
      sig { params(repository: T.nilable(Repository), store: T.nilable(ArtifactStore)).void }
      def initialize(repository:, store:)
        @repository = repository
        @store = store
      end

      # Install all dependencies of this integration type.
      #
      # @param dependencies [Array<Dependency>] all deps for this integration type
      sig { params(dependencies: T::Array[Dependency]).void }
      def install_all(dependencies)
        raise NotImplementedError, "#{self.class}#install_all must be implemented"
      end

      private

      # Attempt the block for every dep, isolating failures so one bad dep
      # never blocks the rest of the batch. Callers raise PartialInstallError
      # themselves (after skipping any batch post-processing that requires a
      # fully-successful set).
      #
      # @param dependencies [Array<Dependency>]
      # @yieldparam dep [Dependency] the dep to install
      # @return [Array<[String, StandardError]>] failed dep name → its error
      sig do
        params(
          dependencies: T::Array[Dependency],
          blk: T.proc.params(dep: Dependency).void,
        ).returns(T::Array[[String, StandardError]])
      end
      def collect_failures(dependencies, &blk)
        failures = T.let([], T::Array[[String, StandardError]])
        dependencies.each do |dep|
          blk.call(dep)
        rescue StandardError => e
          failures << [dep.name, e]
        end
        failures
      end

      sig { returns(T.nilable(Repository)) }
      attr_reader :repository

      sig { returns(T.nilable(ArtifactStore)) }
      attr_reader :store

      # The store, for integrations that cannot work without one (the
      # Registry always wires one; a nil store is a test double's choice).
      #
      # @return [ArtifactStore]
      sig { returns(ArtifactStore) }
      def store!
        T.must(@store)
      end

      # The tree key for a large host-installed dep (the ~30GB engine, the
      # ~15GB server): its declared install_dir is the base, its locked
      # version (gh tag / steam buildid) the version, the integration's marker
      # the marker. Distinct locked versions coexist in the store instead of
      # overwriting, so switching branches never reinstalls and concurrent jobs
      # on different versions never collide; dev's mount resolution
      # (BuildContainer.resolve_versioned_volumes) maps the configured volume
      # onto the store's path for the locked version.
      #
      # @param dep [Dependency] a dep whose metadata carries "install_dir"
      # @param marker [String] the integration's marker file name
      # @return [TreeKey]
      sig { params(dep: Dependency, marker: String).returns(TreeKey) }
      def tree_key(dep, marker:)
        TreeKey.new(base: dep.metadata.fetch("install_dir"), version: dep.version, marker:)
      end
    end
  end
end

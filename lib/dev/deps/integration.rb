# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "../data_root"
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

      # The data-root prefix every tree base starts with; the store re-roots it.
      TREES_ROOT = Dev::DataRoot::HOME_ROOT

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

      class << self
        extend T::Sig

        # Where a tree integration's dependency lives in the store, composed
        # from the integration's placement rule: `<data root>/<integration>/
        # <identity>` as the base, the locked version (gh tag, steam buildid,
        # sdk version) as the version, the integration's marker as the marker.
        # The base is a `~/.dev`-rooted string that the store re-roots onto
        # its own data root; the identity comes from the lock, never from the
        # manifest, so two projects naming the same release differently share
        # one tree and two projects naming different releases alike do not
        # collide. Distinct locked versions coexist beside each other, so
        # switching branches never reinstalls and concurrent jobs on different
        # versions never collide.
        #
        # Tree integrations (gh, steam, wwise) override this; the rest have
        # no tree and say so.
        #
        # @param dep [Dependency] a locked dependency of this integration
        # @return [TreeKey]
        # @raise [NotImplementedError] for an integration that installs no tree
        sig { overridable.params(dep: Dependency).returns(TreeKey) }
        def tree_key(dep)
          raise NotImplementedError, "#{self} installs no tree"
        end
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

      # Instance-side convenience over {.tree_key}.
      #
      # @param dep [Dependency]
      # @return [TreeKey]
      sig { params(dep: Dependency).returns(TreeKey) }
      def tree_key(dep)
        self.class.tree_key(dep)
      end
    end
  end
end

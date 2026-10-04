# typed: strict
# frozen_string_literal: true

require "pathname"
require "sorbet-runtime"

module Dev
  module Deps
    # Names one version-keyed tree in an ArtifactStore.
    #
    # `base` is the artifact's configured home as the project declares it
    # (a dep's `install_dir`, e.g. "~/.dev/engines/unreal-engine-css"); the
    # store decides where that lands on disk. `platform` separates builds
    # that are only valid on one OS/arch (a compiled Ruby, native gems) when
    # one data root serves several — the host and the container it mounts
    # the root into. `marker` is the file a published tree carries, holding
    # its version; it is part of the key so trees published by earlier devs
    # under their integration's marker name stay addressable.
    class TreeKey < T::Struct
      DEFAULT_MARKER = ".dev-artifact"

      const :base, String
      const :version, String
      const :marker, String, default: DEFAULT_MARKER
      const :platform, T.nilable(String), default: nil
    end

    # Port: where dependency artifacts live, however they are backed.
    #
    # Two shapes of artifact share one store because they share one policy
    # (content-addressed, immutable once published, versions side by side,
    # reclaimed by `dev cache gc`):
    #
    # - **trees** — version-keyed directories (the engine, a server depot,
    #   a toolchain Ruby). Built in staging, published atomically, found by
    #   their marker. First writer wins; a published tree is never replaced.
    # - **blobs** — content-addressed files (downloaded archives), keyed by
    #   the path the Repository builds: "<integration>/<name>-<version>-<hash>.ext".
    #
    # Implementations: LocalStore (a directory tree under the data root).
    # Remote backends (a CI cache, an OCI registry) are dev#27's subject;
    # they implement this same interface.
    class ArtifactStore
      extend T::Sig
      extend T::Helpers
      abstract!

      # Raised by {#publish_tree} when the block hands back a directory that
      # is not inside the staging dir it was given.
      class PublishOutsideStagingError < StandardError; end

      # The published tree for a key, or nil when none (or only a partial
      # one) exists.
      #
      # @param key [TreeKey]
      # @return [Pathname, nil]
      sig { abstract.params(key: TreeKey).returns(T.nilable(Pathname)) }
      def tree(key); end

      # Where the key's tree is — or would be — published. For mount sources
      # and build contexts, which name the path before anything is installed.
      #
      # @param key [TreeKey]
      # @return [Pathname]
      sig { abstract.params(key: TreeKey).returns(Pathname) }
      def tree_path(key); end

      # Build and publish a tree. Yields a fresh staging directory; the block
      # builds there and returns the directory to publish (the staging dir
      # itself or a subdirectory of it). The store stamps the marker and
      # publishes atomically. If another publisher won meanwhile, the existing
      # tree stands and is returned. Staging never survives the call.
      #
      # @param key [TreeKey]
      # @yieldparam staging [Pathname] an empty directory on the destination's filesystem
      # @yieldreturn [Pathname] the finished directory to publish
      # @return [Pathname] the published tree
      # @raise [PublishOutsideStagingError] when the block returns a path outside staging
      sig do
        abstract
          .params(key: TreeKey, blk: T.proc.params(staging: Pathname).returns(Pathname))
          .returns(Pathname)
      end
      def publish_tree(key, &blk); end

      # Every version published under a base (for a platform), by name.
      #
      # @param base [String] the configured base, as in {TreeKey#base}
      # @param platform [String, nil] as in {TreeKey#platform}
      # @return [Array<String>] version names, unordered
      sig { abstract.params(base: String, platform: T.nilable(String)).returns(T::Array[String]) }
      def tree_versions(base, platform: nil); end

      # Delete one published tree. No-op when absent.
      #
      # @param key [TreeKey]
      # @return [void]
      sig { abstract.params(key: TreeKey).void }
      def remove_tree(key); end

      # Delete staging directories a crashed publisher left under a base.
      #
      # @param base [String]
      # @param platform [String, nil]
      # @return [Array<Pathname>] what was removed
      sig { abstract.params(base: String, platform: T.nilable(String)).returns(T::Array[Pathname]) }
      def remove_orphan_staging(base, platform: nil); end

      # The blob for a key, or nil when absent.
      #
      # @param key [String]
      # @return [Pathname, nil]
      sig { abstract.params(key: String).returns(T.nilable(Pathname)) }
      def blob(key); end

      # Where the key's blob is — or would be.
      #
      # @param key [String]
      # @return [Pathname]
      sig { abstract.params(key: String).returns(Pathname) }
      def blob_path(key); end

      # Store a blob, taking ownership of the file (it is moved, not copied).
      #
      # @param key [String]
      # @param file [File] open handle to the source
      # @return [void]
      sig { abstract.params(key: String, file: File).void }
      def put_blob(key, file); end
    end
  end
end

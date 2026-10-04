# typed: strict
# frozen_string_literal: true

require "fileutils"
require "pathname"
require "securerandom"
require_relative "../data_root"
require_relative "artifact_store"

module Dev
  module Deps
    # The ArtifactStore backed by a directory tree under the data root.
    #
    # Layout (unchanged from before the store existed, so every tree already
    # on a machine stays addressable):
    #
    #   <base>/<version>/…                 tree, `base` re-rooted by DataRoot
    #   <base>/<platform>/<version>/…      platform-keyed tree
    #   <base>/.staging-<pid>-<rand>/      a publish in progress
    #   <root>/cache/<key>                 blob
    #
    # Publishing is a same-filesystem rename of a staging dir built beside
    # the versions: atomic, so a reader never sees a tree without its marker,
    # and crash-safe, so a killed publisher only ever leaves orphan staging.
    class LocalStore < ArtifactStore
      extend T::Sig

      STAGING_PREFIX = ".staging-"
      BLOB_DIR = "cache"
      TOOL_CACHES_DIR = "tool-caches"

      # @param data_root [String] where "~/.dev" bases re-root (tests use a tmpdir)
      sig { params(data_root: String).void }
      def initialize(data_root: Dev::DataRoot.path)
        super()
        @data_root = data_root
      end

      sig { override.params(key: TreeKey).returns(T.nilable(Pathname)) }
      def tree(key)
        path = tree_path(key)
        marker = path / key.marker
        marker.file? && marker.read.strip == key.version ? path : nil
      end

      sig { override.params(key: TreeKey).returns(Pathname) }
      def tree_path(key)
        base_path(key.base, key.platform) / key.version
      end

      sig do
        override
          .params(key: TreeKey, blk: T.proc.params(staging: Pathname).returns(Pathname))
          .returns(Pathname)
      end
      def publish_tree(key, &blk)
        destination = tree_path(key)
        staging = new_staging_dir(base_path(key.base, key.platform))
        staging.mkpath
        begin
          built = blk.call(staging)
          unless inside?(built, staging)
            raise PublishOutsideStagingError, "#{built} is not inside the staging dir #{staging}"
          end

          (built / key.marker).write(key.version)
          rename_into_place(built, destination)
          destination
        ensure
          FileUtils.rm_rf(staging)
        end
      end

      sig { override.params(key: TreeKey, blk: T.proc.params(dir: Pathname).void).returns(Pathname) }
      def build_tree(key, &blk)
        published = tree(key)
        return published if published

        dir = tree_path(key)
        FileUtils.rm_rf(dir)
        dir.mkpath
        blk.call(dir)
        (dir / key.marker).write(key.version)
        dir
      end

      sig { override.params(key: TreeKey).returns(Pathname) }
      def workdir(key)
        dir = tree_path(key)
        dir.mkpath
        dir
      end

      sig { override.params(base: String, platform: T.nilable(String)).returns(T::Array[String]) }
      def tree_versions(base, platform: nil)
        dir = base_path(base, platform)
        return [] unless dir.directory?

        dir.children.select { |child| child.directory? && !staging?(child) }.map { |child| child.basename.to_s }
      end

      sig { override.params(key: TreeKey).void }
      def remove_tree(key)
        FileUtils.rm_rf(tree_path(key))
      end

      sig { override.params(base: String, platform: T.nilable(String)).returns(T::Array[Pathname]) }
      def remove_orphan_staging(base, platform: nil)
        dir = base_path(base, platform)
        return [] unless dir.directory?

        dir.children.select { |child| staging?(child) }.each { |orphan| FileUtils.rm_rf(orphan) }
      end

      sig { override.params(key: String).returns(T.nilable(Pathname)) }
      def blob(key)
        path = blob_path(key)
        path.file? ? path : nil
      end

      sig { override.params(key: String).returns(Pathname) }
      def blob_path(key)
        Pathname(@data_root) / BLOB_DIR / key
      end

      sig { override.params(key: String, file: File).void }
      def put_blob(key, file)
        destination = blob_path(key)
        destination.dirname.mkpath
        FileUtils.mv(file.path, destination)
      end

      sig { override.params(name: String).returns(Pathname) }
      def tool_cache(name)
        dir = tool_caches_root / name
        dir.mkpath
        dir
      end

      sig { override.returns(T::Array[String]) }
      def tool_caches
        return [] unless tool_caches_root.directory?

        tool_caches_root.children.select(&:directory?).map { |child| child.basename.to_s }.sort
      end

      sig { override.params(name: String).void }
      def remove_tool_cache(name)
        FileUtils.rm_rf(tool_caches_root / name)
      end

      private

      # @return [Pathname] the directory holding every tool's cache
      sig { returns(Pathname) }
      def tool_caches_root
        Pathname(@data_root) / TOOL_CACHES_DIR
      end

      # The on-disk directory holding a base's versions.
      #
      # @param base [String] configured base
      # @param platform [String, nil]
      # @return [Pathname]
      sig { params(base: String, platform: T.nilable(String)).returns(Pathname) }
      def base_path(base, platform)
        path = Pathname(Dev::DataRoot.expand(base, root: @data_root))
        platform ? path / platform : path
      end

      # A unique staging dir beside the versions it will join.
      #
      # @param base_dir [Pathname]
      # @return [Pathname]
      sig { params(base_dir: Pathname).returns(Pathname) }
      def new_staging_dir(base_dir)
        base_dir / "#{STAGING_PREFIX}#{Process.pid}-#{SecureRandom.hex(4)}"
      end

      # @param path [Pathname]
      # @return [Boolean]
      sig { params(path: Pathname).returns(T::Boolean) }
      def staging?(path)
        path.directory? && path.basename.to_s.start_with?(STAGING_PREFIX)
      end

      # @param path [Pathname]
      # @param staging [Pathname]
      # @return [Boolean]
      sig { params(path: Pathname, staging: Pathname).returns(T::Boolean) }
      def inside?(path, staging)
        path == staging || path.to_s.start_with?("#{staging}/")
      end

      # First writer wins: renaming onto an existing version dir raises, which
      # means another publisher already finished — its tree stands, ours is
      # dropped by the caller's staging cleanup.
      #
      # @param built [Pathname]
      # @param destination [Pathname]
      # @return [void]
      sig { params(built: Pathname, destination: Pathname).void }
      def rename_into_place(built, destination)
        destination.dirname.mkpath
        File.rename(built.to_s, destination.to_s)
      rescue Errno::ENOTEMPTY, Errno::EEXIST, Errno::ENOTDIR, Errno::EISDIR
        nil
      end
    end
  end
end

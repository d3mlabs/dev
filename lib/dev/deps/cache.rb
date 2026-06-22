# frozen_string_literal: true

require "fileutils"
require "pathname"

module Dev
  module Deps
    # Content-addressed download cache shared across projects.
    #
    # Stores raw downloaded archives (tarballs, zips) keyed by a structured
    # path: <integration>/<name>-<version>-<hash>.ext
    #
    # The key is built by the Repository, which has the context to construct
    # it. The Cache itself is a dumb key-value store.
    #
    # Two-layer caching pattern: this global cache is the download
    # accelerator; project-local install directories are managed by
    # each Integration.
    class Cache
      # Raised when a requested key is not in the cache.
      class CacheMissError < StandardError; end

      DEFAULT_DIR = Pathname.new(File.expand_path("~/.dev/cache"))

      # @param cache_dir [Pathname] root directory for cached artifacts
      def initialize(cache_dir: DEFAULT_DIR)
        @cache_dir = Pathname(cache_dir)
      end

      # Store an artifact in the cache. Takes ownership (moves the file).
      #
      # @param key  [String] cache key (e.g. "cmake/boost-1.90.0-a1b2c3.tar.gz")
      # @param file [File]   open handle to the source artifact
      def store(key, file)
        dest = path_for(key)
        FileUtils.mkdir_p(dest.dirname)
        FileUtils.mv(file.path, dest)
      end

      # Retrieve a cached artifact.
      #
      # @param key [String] cache key
      # @return [File] read-only handle to the cached artifact
      # @raise [Cache::CacheMissError] if the key is not in the cache
      def fetch(key)
        path = path_for(key)
        raise CacheMissError, "Cache miss: #{key}" unless path.exist?

        File.open(path, "rb")
      end

      # Check whether a key exists in the cache.
      #
      # @param key [String] cache key
      # @return [Boolean]
      def exists?(key)
        path_for(key).exist?
      end

      # Resolve a key to its absolute on-disk path (whether or not it exists).
      # Lets consumers locate a cached artifact without reconstructing the
      # cache-dir layout.
      #
      # @param key [String] cache key
      # @return [Pathname]
      def path(key)
        path_for(key)
      end

      private

      def path_for(key)
        @cache_dir / key
      end
    end
  end
end

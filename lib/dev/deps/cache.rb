# frozen_string_literal: true

require "fileutils"
require "pathname"

module Dev
  module Deps
    # Content-addressed download cache shared across projects.
    #
    # Stores raw downloaded archives (tarballs, zips) keyed by Pathname.
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
      # The file's basename is used as the cache key.
      #
      # @param file [File] open handle to the source artifact
      def store(file)
        FileUtils.mkdir_p(@cache_dir)
        FileUtils.mv(file.path, @cache_dir / File.basename(file.path))
      end

      # Retrieve a cached artifact.
      #
      # @param key [Pathname] cache key
      # @return [File] read-only handle to the cached artifact
      # @raise [Cache::CacheMissError] if the key is not in the cache
      def fetch(key)
        path = path_for(key)
        raise CacheMissError, "Cache miss: #{key}" unless path.exist?

        File.open(path, "rb")
      end

      # Check whether a key exists in the cache.
      #
      # @param key [Pathname] cache key
      # @return [Boolean]
      def exists?(key)
        path_for(key).exist?
      end

      private

      def path_for(key)
        @cache_dir / Pathname(key).to_s.tr("/", "_")
      end
    end
  end
end

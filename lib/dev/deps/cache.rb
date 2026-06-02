# frozen_string_literal: true

require "fileutils"

module Dev
  module Deps
    # Content-addressed download cache shared across projects.
    #
    # Stores raw downloaded archives (tarballs, zips) keyed by integrity hash.
    # Two-layer caching pattern: this global cache is the download accelerator;
    # project-local install directories are managed by each Integration.
    #
    # Default location: ~/.dev/cache
    class Cache
      # @param cache_dir [String] root directory for cached artifacts
      def initialize(cache_dir: File.expand_path("~/.dev/cache"))
        @cache_dir = cache_dir
      end

      # Store an artifact in the cache. Copies the file (does not move).
      #
      # @param hash [String] integrity hash (e.g. "SHA256=deadbeef")
      # @param path [String] path to the artifact file to cache
      def store(hash, path)
        FileUtils.mkdir_p(@cache_dir)
        dest = path_for(hash)
        FileUtils.cp(path, dest)
      end

      # Retrieve a cached artifact path, or nil if not cached.
      #
      # @param hash [String] integrity hash
      # @return [String, nil] path to cached file, or nil
      def fetch(hash)
        dest = path_for(hash)
        File.exist?(dest) ? dest : nil
      end

      # Check whether an artifact is in the cache.
      #
      # @param hash [String] integrity hash
      # @return [Boolean]
      def has?(hash)
        File.exist?(path_for(hash))
      end

      private

      def path_for(hash)
        File.join(@cache_dir, hash.tr("/", "_"))
      end
    end
  end
end

# frozen_string_literal: true

require "fileutils"
require "pathname"

module Dev
  module Deps
    # Content-addressed download cache shared across projects.
    #
    # Stores raw downloaded archives (tarballs, zips) keyed by a unique
    # identifier. Two-layer caching pattern: this global cache is the
    # download accelerator; project-local install directories are managed
    # by each Integration.
    class Cache
      # Strong type for cache keys — validates that the key is safe for
      # use as a filesystem path component.
      class Key
        attr_reader :value

        def initialize(value)
          raise ArgumentError, "Cache key cannot be blank" if value.nil? || value.strip.empty?

          @value = value.to_s
        end

        # Filesystem-safe representation (slashes replaced with underscores).
        def to_path_component
          @value.tr("/", "_")
        end

        def to_s = @value
        def ==(other) = other.is_a?(Key) && @value == other.value
        def eql?(other) = self == other
        def hash = @value.hash
      end

      DEFAULT_DIR = Pathname.new(File.expand_path("~/.dev/cache"))

      # @param cache_dir [Pathname] root directory for cached artifacts
      def initialize(cache_dir: DEFAULT_DIR)
        @cache_dir = Pathname(cache_dir)
      end

      # Store an artifact in the cache. Moves the file (takes ownership).
      #
      # @param key  [Key, String] unique identifier for this artifact
      # @param path [Pathname]    path to the artifact file
      def store(key, path)
        key = Key.new(key) unless key.is_a?(Key)
        path = Pathname(path)

        FileUtils.mkdir_p(@cache_dir)
        FileUtils.mv(path, path_for(key))
      end

      # Retrieve a cached artifact path, or nil if not cached.
      #
      # @param key [Key, String] unique identifier
      # @return [Pathname, nil]
      def fetch(key)
        key = Key.new(key) unless key.is_a?(Key)
        dest = path_for(key)
        dest.exist? ? dest : nil
      end

      # Check whether an artifact is in the cache.
      #
      # @param key [Key, String] unique identifier
      # @return [Boolean]
      def key?(key)
        key = Key.new(key) unless key.is_a?(Key)
        path_for(key).exist?
      end

      private

      def path_for(key)
        @cache_dir / key.to_path_component
      end
    end
  end
end

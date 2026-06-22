# frozen_string_literal: true

require_relative "lockfile"
require_relative "cache"
require_relative "ficsit_integration"

module Dev
  module Deps
    # Read-only accessor over the lockfile + content cache, surfaced as
    # `dev deps <subcommand>`. Today it answers one question: where is the
    # cached zip for a locked ficsit mod platform? Consumers (deploy / the
    # integration harness) use this instead of reconstructing cache keys, so the
    # key scheme stays an implementation detail of the integration.
    class Accessor
      class UsageError < StandardError; end
      class NotLockedError < StandardError; end
      class PlatformNotLockedError < StandardError; end
      class NotCachedError < StandardError; end

      USAGE = "usage: dev deps path ficsit <mod> <platform>"

      # @param lockfile [Lockfile]
      # @param cache [Cache]
      def initialize(lockfile:, cache:)
        @lockfile = lockfile
        @cache = cache
      end

      # Dispatch a `dev deps …` invocation and print the result.
      #
      # @param args [Array<String>] argv after the "deps" command
      # @param out [IO] output stream
      # @raise [UsageError] on an unrecognized invocation
      def run(args, out: $stdout)
        subcommand, *rest = args
        case subcommand
        when "path" then out.puts(path(*rest).to_s)
        else raise UsageError, USAGE
        end
      end

      # Resolve the cached artifact path for a locked dependency platform.
      #
      # @param integration [String] integration name (only "ficsit" supported)
      # @param name [String] dependency name (e.g. "SML")
      # @param platform [String] ficsit target name (e.g. "LinuxServer")
      # @return [Pathname] absolute path to the cached zip
      # @raise [UsageError] for a missing/unsupported integration
      # @raise [NotLockedError] if the dep isn't in the lockfile
      # @raise [PlatformNotLockedError] if the platform isn't locked for the dep
      # @raise [NotCachedError] if the zip isn't in the cache (run dev up)
      def path(integration = nil, name = nil, platform = nil)
        raise UsageError, USAGE unless integration == "ficsit" && name && platform

        dep = find_dep(:ficsit, name)
        target = locked_platform(dep, platform)
        key = FicsitIntegration.cache_key(
          name: dep.name, version: dep.version, platform: platform, hash: target["hash"],
        )
        unless @cache.exists?(key)
          raise NotCachedError,
                "#{name} (#{platform}) is not cached — run dev up to download it"
        end

        @cache.path(key)
      end

      private

      # @param integration [Symbol]
      # @param name [String]
      # @return [Dependency]
      def find_dep(integration, name)
        dep = @lockfile.read.find { |d| d.integration == integration && d.name == name }
        raise NotLockedError, "#{name} (#{integration}) is not in the lockfile — run dev update-deps" unless dep

        dep
      end

      # @param dep [Dependency]
      # @param platform [String]
      # @return [Hash] the locked { "hash", "link" } for the platform
      def locked_platform(dep, platform)
        platforms = dep.metadata["platforms"] || {}
        target = platforms[platform]
        unless target
          available = platforms.keys.join(", ")
          raise PlatformNotLockedError,
                "#{dep.name} has no locked #{platform} platform (locked: #{available})"
        end

        target
      end
    end
  end
end

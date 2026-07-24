# frozen_string_literal: true

require_relative "lockfile"
require_relative "cache"
require_relative "ficsit_integration"
require_relative "xcode_integration"

module Dev
  module Deps
    # Read-only accessor over the lockfile + content cache, surfaced as
    # `dev deps <subcommand>`. It answers "where is a locked dep's artifact?"
    # — the cached zip for a ficsit mod platform, the DEVELOPER_DIR for the
    # pinned Xcode — so consumers (deploy, build scripts, CI) resolve paths
    # from the lockfile instead of reconstructing dev's layout conventions.
    class Accessor
      class UsageError < StandardError; end
      class NotLockedError < StandardError; end
      class PlatformNotLockedError < StandardError; end
      class NotCachedError < StandardError; end
      class NotInstalledError < StandardError; end

      USAGE = "usage: dev deps path ficsit <mod> <platform> | dev deps path xcode"

      # @param lockfile [Lockfile]
      # @param cache [Cache]
      # @param xcode_install_root [String] where Xcode bundles live (tests use a tmpdir)
      def initialize(lockfile:, cache:, xcode_install_root: XcodeIntegration::INSTALL_ROOT)
        @lockfile = lockfile
        @cache = cache
        @xcode_install_root = xcode_install_root
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

      # Resolve the artifact path for a locked dependency.
      #
      # @param integration [String] integration name ("ficsit" or "xcode")
      # @param name [String, nil] dependency name (e.g. "SML"; unused for xcode)
      # @param platform [String, nil] ficsit target name (e.g. "LinuxServer")
      # @return [Pathname] absolute path to the artifact
      # @raise [UsageError] for a missing/unsupported integration
      # @raise [NotLockedError] if the dep isn't in the lockfile
      # @raise [PlatformNotLockedError] if the platform isn't locked for the dep
      # @raise [NotCachedError] if the zip isn't in the cache (run dev up)
      # @raise [NotInstalledError] if the pinned Xcode isn't installed (run dev up)
      def path(integration = nil, name = nil, platform = nil)
        case integration
        when "ficsit" then ficsit_path(name, platform)
        when "xcode" then xcode_developer_dir
        else raise UsageError, USAGE
        end
      end

      private

      # @param name [String, nil]
      # @param platform [String, nil]
      # @return [Pathname]
      def ficsit_path(name, platform)
        raise UsageError, USAGE unless name && platform

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

      # The DEVELOPER_DIR of the locked Xcode pin — what build scripts export
      # so xcodebuild rides the pin (e.g. unreal-engine's Mac release job).
      #
      # @return [Pathname]
      def xcode_developer_dir
        dep = find_dep(:xcode, "xcode")
        developer_dir = Pathname(XcodeIntegration.developer_dir(dep.version, root: @xcode_install_root))
        unless developer_dir.directory?
          raise NotInstalledError,
            "xcode #{dep.version} is not installed at " \
            "#{XcodeIntegration.app_path(dep.version, root: @xcode_install_root)} — run dev up"
        end

        developer_dir
      end

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

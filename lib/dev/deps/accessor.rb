# typed: strict
# frozen_string_literal: true

require "stringio"
require_relative "dependency"
require_relative "lockfile"
require_relative "cache"
require_relative "ficsit_integration"
require_relative "xcode_integration"
require_relative "gh_integration"
require_relative "../data_root"

module Dev
  module Deps
    # Read-only accessor over the lockfile + content cache, surfaced as
    # `dev deps <subcommand>`. It answers "where is a locked dep's artifact?"
    # — the cached zip for a ficsit mod platform, the DEVELOPER_DIR for the
    # pinned Xcode, the version-keyed install dir of a gh release — so
    # consumers (deploy, build scripts, CI) resolve paths from the lockfile
    # instead of reconstructing dev's layout conventions.
    class Accessor
      extend T::Sig

      class UsageError < StandardError; end
      class NotLockedError < StandardError; end
      class PlatformNotLockedError < StandardError; end
      class NotCachedError < StandardError; end
      class NotInstalledError < StandardError; end

      USAGE = "usage: dev deps path ficsit <mod> <platform> | dev deps path xcode | dev deps path gh <name>"

      # @param lockfile [Lockfile]
      # @param cache [Cache]
      # @param xcode_install_root [String] where Xcode bundles live (tests use a tmpdir)
      # @param data_root [String] where `~/.dev` install_dirs re-root (tests use a tmpdir)
      sig do
        params(lockfile: Lockfile, cache: Cache, xcode_install_root: String, data_root: String).void
      end
      def initialize(
        lockfile:,
        cache:,
        xcode_install_root: XcodeIntegration::INSTALL_ROOT,
        data_root: Dev::DataRoot.path
      )
        @lockfile = lockfile
        @cache = cache
        @xcode_install_root = xcode_install_root
        @data_root = data_root
      end

      # Dispatch a `dev deps …` invocation and print the result.
      #
      # @param args [Array<String>] argv after the "deps" command
      # @param out [IO, StringIO] output stream
      # @raise [UsageError] on an unrecognized invocation
      sig { params(args: T::Array[String], out: T.any(IO, StringIO)).void }
      def run(args, out: $stdout)
        subcommand, *rest = args
        case subcommand
        when "path"
          raise UsageError, USAGE if rest.size > 3

          integration, name, platform = rest
          out.puts(path(integration, name, platform).to_s)
        else raise UsageError, USAGE
        end
      end

      # Resolve the artifact path for a locked dependency.
      #
      # @param integration [String] integration name ("ficsit", "xcode" or "gh")
      # @param name [String, nil] dependency name (e.g. "SML", "UnrealEngineMac"; unused for xcode)
      # @param platform [String, nil] ficsit target name (e.g. "LinuxServer")
      # @return [Pathname] absolute path to the artifact
      # @raise [UsageError] for a missing/unsupported integration
      # @raise [NotLockedError] if the dep isn't in the lockfile
      # @raise [PlatformNotLockedError] if the platform isn't locked for the dep
      # @raise [NotCachedError] if the zip isn't in the cache (run dev up)
      # @raise [NotInstalledError] if the pinned Xcode or gh release isn't installed (run dev up)
      sig do
        params(
          integration: T.nilable(String),
          name: T.nilable(String),
          platform: T.nilable(String),
        ).returns(Pathname)
      end
      def path(integration = nil, name = nil, platform = nil)
        case integration
        when "ficsit" then ficsit_path(name, platform)
        when "xcode" then xcode_developer_dir
        when "gh" then gh_install_dir(name)
        else raise UsageError, USAGE
        end
      end

      private

      # The version-keyed install dir of a locked gh release — the immutable
      # directory GhIntegration publishes under the dep's install_dir, re-rooted
      # onto the data root. Resolved from the lock rather than the `current`
      # pointer so a checkout always gets the tag its lockfile names, not
      # whatever this machine installed last.
      #
      # @param name [String, nil]
      # @return [Pathname]
      sig { params(name: T.nilable(String)).returns(Pathname) }
      def gh_install_dir(name)
        raise UsageError, USAGE unless name

        dep = find_dep(:gh, name)
        base_dir = Dev::DataRoot.expand(dep.metadata.fetch("install_dir"), root: @data_root)
        version_dir = Pathname(base_dir) / dep.version
        marker = version_dir / GhIntegration::MARKER_FILE
        unless marker.file? && marker.read.strip == dep.version
          raise NotInstalledError, "#{name}@#{dep.version} is not installed at #{version_dir} — run dev up"
        end

        version_dir
      end

      # @param name [String, nil]
      # @param platform [String, nil]
      # @return [Pathname]
      sig { params(name: T.nilable(String), platform: T.nilable(String)).returns(Pathname) }
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
      sig { returns(Pathname) }
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
      sig { params(integration: Symbol, name: String).returns(Dependency) }
      def find_dep(integration, name)
        dep = @lockfile.read.find { |d| d.integration == integration && d.name == name }
        raise NotLockedError, "#{name} (#{integration}) is not in the lockfile — run dev update-deps" unless dep

        dep
      end

      # @param dep [Dependency]
      # @param platform [String]
      # @return [Hash] the locked { "hash", "link" } for the platform
      sig { params(dep: Dependency, platform: String).returns(T::Hash[String, T.untyped]) }
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

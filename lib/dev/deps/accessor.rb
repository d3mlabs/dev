# typed: strict
# frozen_string_literal: true

require "stringio"
require_relative "dependency"
require_relative "lockfile"
require_relative "artifact_store"
require_relative "ficsit_integration"
require_relative "xcode_integration"
require_relative "gh_integration"
require_relative "wwise_integration"

module Dev
  module Deps
    # Read-only accessor over the lockfile + artifact store, surfaced as
    # `dev deps path`. It answers "where is a locked dep's artifact?"
    # — the cached zip for a ficsit mod platform, the DEVELOPER_DIR for the
    # pinned Xcode, the published tree of a gh release or a wwise cache — so
    # consumers (deploy, build scripts, CI) resolve paths from the lockfile
    # instead of reconstructing the store's layout.
    class Accessor
      extend T::Sig

      # All five are the caller's problem, not dev's, so they descend from
      # the two roots Runner#exit_for prints as a clean `dev: …` line (exit
      # 1): a malformed invocation or an operand the lockfile does not know
      # is an ArgumentError; a locked dep whose artifact is not provisioned
      # yet ("run dev up") is a RuntimeError.
      class UsageError < RuntimeError; end
      class NotLockedError < ArgumentError; end
      class PlatformNotLockedError < ArgumentError; end
      class NotCachedError < RuntimeError; end
      class NotInstalledError < RuntimeError; end

      USAGE = "usage: dev deps path ficsit <mod> <platform> | dev deps path xcode | " \
        "dev deps path gh <name> | dev deps path wwise <name>"

      # @param lockfile [Lockfile]
      # @param store [ArtifactStore] where published trees and cached blobs live
      # @param xcode_install_root [String] where Xcode bundles live (tests use a tmpdir)
      sig { params(lockfile: Lockfile, store: ArtifactStore, xcode_install_root: String).void }
      def initialize(lockfile:, store:, xcode_install_root: XcodeIntegration::INSTALL_ROOT)
        @lockfile = lockfile
        @store = store
        @xcode_install_root = xcode_install_root
      end

      # Print the artifact path a `dev deps path …` invocation asks for.
      #
      # @param args [Array<String>] argv after `deps path`: the integration,
      #   then its name/platform operands
      # @param out [IO, StringIO] output stream
      # @raise [UsageError] on an unrecognized invocation
      sig { params(args: T::Array[String], out: T.any(IO, StringIO)).void }
      def print_path(args, out: $stdout)
        raise UsageError, USAGE if args.size > 3

        integration, name, platform = args
        out.puts(path(integration, name, platform).to_s)
      end

      # Resolve the artifact path for a locked dependency.
      #
      # @param integration [String] integration name ("ficsit", "xcode", "gh" or "wwise")
      # @param name [String, nil] dependency name (e.g. "SML", "UnrealEngineMac", "Wwise"; unused for xcode)
      # @param platform [String, nil] ficsit target name (e.g. "LinuxServer")
      # @return [Pathname] absolute path to the artifact
      # @raise [UsageError] for a missing/unsupported integration
      # @raise [NotLockedError] if the dep isn't in the lockfile
      # @raise [PlatformNotLockedError] if the platform isn't locked for the dep
      # @raise [NotCachedError] if the zip isn't in the cache (run dev up)
      # @raise [NotInstalledError] if the pinned Xcode, gh release or wwise cache isn't installed (run dev up)
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
        when "gh" then published_tree(:gh, name, marker: GhIntegration::MARKER_FILE)
        when "wwise" then published_tree(:wwise, name, marker: WwiseIntegration::MARKER_FILE)
        else raise UsageError, USAGE
        end
      end

      private

      # The published tree of a locked install_dir dep — the immutable
      # directory its integration publishes to the store under the dep's
      # install_dir (a gh release's tree, a wwise cache). Resolved from the
      # lock so a checkout always gets the version its lockfile names, not
      # whatever this machine installed last.
      #
      # @param integration [Symbol]
      # @param name [String, nil]
      # @param marker [String] the integration's marker file name
      # @return [Pathname]
      sig { params(integration: Symbol, name: T.nilable(String), marker: String).returns(Pathname) }
      def published_tree(integration, name, marker:)
        raise UsageError, USAGE unless name

        dep = find_dep(integration, name)
        key = TreeKey.new(base: dep.metadata.fetch("install_dir"), version: dep.version, marker:)
        @store.tree(key) ||
          raise(NotInstalledError, "#{name}@#{dep.version} is not installed at #{@store.tree_path(key)} — run dev up")
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
        @store.blob(key) ||
          raise(NotCachedError, "#{name} (#{platform}) is not cached — run dev up to download it")
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
        raise NotLockedError, "#{name} (#{integration}) is not in the lockfile — run dev deps update" unless dep

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

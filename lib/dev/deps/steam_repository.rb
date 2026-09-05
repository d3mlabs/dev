# typed: strict
# frozen_string_literal: true

require_relative "package"
require_relative "package_id"
require_relative "package_version"
require_relative "repository"
require_relative "steam_cmd"

module Dev
  module Deps
    # Resolves a Steam application (e.g. the Satisfactory Dedicated Server) to a
    # pinned build.
    #
    # The "version" is the Steam buildid: either an explicitly pinned one from
    # the declaration, or the current public-branch buildid resolved via
    # SteamCMD's +app_info_print. There is no content hash — Steam exposes no
    # stable per-build digest, so integrity is delegated to SteamCMD's
    # `app_update … validate` at install time (the same nil-hash shape brew
    # casks use).
    #
    # Declared in dependencies.rb as:
    #   steam "SatisfactoryServer",
    #         app: 1690800,
    #         install_dir: "~/.dev/satisfactory-server"
    class SteamRepository < Repository
      extend T::Sig

      # Report a Steam app's universe: one buildid, as a singleton.
      #
      # Steam exposes no enumerable build history — the filter locates the
      # build: an explicit "buildid" pin, or the current buildid of "branch"
      # (default public) via SteamCMD. No digest: Steam publishes no stable
      # per-build hash; integrity is SteamCMD's app_update … validate at
      # install.
      #
      # @param id [PackageId] name is the declaration name
      # @param filter [Hash] locator: "app", "install_dir", optionally
      #   "branch", "buildid", "platforms"
      # @return [Package] a singleton universe
      # @raise [SteamCmd::SteamCmdError] if resolving the buildid fails
      sig { override.params(id: PackageId, filter: T::Hash[String, T.untyped]).returns(Package) }
      def find(id, filter: {})
        app = filter["app"]
        branch = filter["branch"] || "public"
        build_id = filter["buildid"] || resolve_build_id(app:, branch:)

        Package.new(
          id: id,
          versions: [
            PackageVersion.new(
              version: build_id.to_s,
              metadata: {
                "app" => app.to_s,
                "branch" => branch,
                "install_dir" => filter["install_dir"],
                "platform" => steam_platform_for(filter["platforms"]),
              },
            ),
          ],
        )
      end

      private

      # Isolated so tests can stub the SteamCMD boundary.
      #
      # @param app [String, Integer]
      # @param branch [String]
      # @return [String] resolved buildid
      sig { params(app: T.any(String, Integer), branch: String).returns(String) }
      def resolve_build_id(app:, branch:)
        SteamCmd.resolve_build_id(app:, branch:)
      end

      # Map the consuming group's platform to a SteamCMD ForcePlatformType value.
      # The dedicated server is Linux-only in our pipeline, so a missing platform
      # defaults to "linux".
      #
      # @param platforms [Array<String, nil>, nil] platforms from the resolver
      # @return [String] steam platform type ("linux" / "windows")
      sig { params(platforms: T.nilable(T::Array[T.nilable(String)])).returns(String) }
      def steam_platform_for(platforms)
        group_platform = Array(platforms).compact.first
        case group_platform
        when "LinuxServer" then "linux"
        when "WindowsServer", "Windows" then "windows"
        when nil then "linux"
        else group_platform.downcase
        end
      end
    end
  end
end

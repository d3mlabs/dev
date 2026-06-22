# frozen_string_literal: true

require_relative "repository"
require_relative "dependency"
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
      # Resolve a Steam app dependency to a pinned Dependency.
      #
      # @param id [Hash] must include "name", "app", "install_dir", "integration",
      #   "group"; optionally "branch" (default "public"), "buildid" (explicit
      #   pin), and "platforms" (the consuming group's platform, e.g. ["LinuxServer"])
      # @return [Dependency]
      # @raise [SteamCmd::SteamCmdError] if resolving the buildid fails
      def fetch(id)
        app = id["app"]
        branch = id["branch"] || "public"
        build_id = id["buildid"] || resolve_build_id(app:, branch:)

        Dependency.new(
          name: id["name"],
          integration: id["integration"].to_sym,
          group: id["group"].to_sym,
          version: build_id.to_s,
          hash: nil,
          metadata: {
            "app" => app.to_s,
            "branch" => branch,
            "install_dir" => id["install_dir"],
            "platform" => steam_platform_for(id["platforms"]),
          },
        )
      end

      private

      # Isolated so tests can stub the SteamCMD boundary.
      #
      # @param app [String, Integer]
      # @param branch [String]
      # @return [String] resolved buildid
      def resolve_build_id(app:, branch:)
        SteamCmd.resolve_build_id(app:, branch:)
      end

      # Map the consuming group's platform to a SteamCMD ForcePlatformType value.
      # The dedicated server is Linux-only in our pipeline, so a missing platform
      # defaults to "linux".
      #
      # @param platforms [Array<String, nil>, nil] platforms from the resolver
      # @return [String] steam platform type ("linux" / "windows")
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

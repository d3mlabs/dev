# frozen_string_literal: true

require "fileutils"
require "open3"
require "shellwords"

module Dev
  module Deps
    # Shared SteamCMD bootstrap + invocation.
    #
    # Both SteamRepository (resolve an app's public buildid) and SteamIntegration
    # (provision the depot) need a working SteamCMD on the host. This module owns
    # the one-time host-OS bootstrap into a shared dir so resolve and install
    # reuse the same SteamCMD install instead of each hand-rolling it.
    #
    # The SteamCMD *binary* always matches the host OS; the *depot* platform is a
    # separate axis the caller forces with +@sSteamCmdForcePlatformType.
    module SteamCmd
      class BootstrapError < StandardError; end
      class SteamCmdError < StandardError; end

      DEFAULT_DIR = File.expand_path("~/.dev/steamcmd")
      LINUX_URL = "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"
      MACOS_URL = "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz"

      module_function

      # Ensure host-OS SteamCMD is installed in dir; return the steamcmd.sh path.
      # The tarball is tiny (~5 MB) and SteamCMD self-updates its runtime on
      # first run, so a warm dir skips the re-download.
      #
      # @param dir [String] install dir for the SteamCMD binary
      # @return [String] path to steamcmd.sh
      # @raise [BootstrapError] if the download/extract fails
      def ensure!(dir = DEFAULT_DIR)
        script = File.join(dir, "steamcmd.sh")
        return script if File.executable?(script)

        FileUtils.mkdir_p(dir)
        url = download_url
        pipeline = "curl -fsSL #{url.shellescape} | tar -xz -C #{dir.shellescape}"
        system("sh", "-c", pipeline) || raise(BootstrapError, "failed to bootstrap SteamCMD from #{url}")
        raise BootstrapError, "SteamCMD bootstrap did not produce #{script}" unless File.executable?(script)

        script
      end

      # @return [String] the SteamCMD tarball URL for the host OS
      def download_url
        RUBY_PLATFORM.include?("darwin") ? MACOS_URL : LINUX_URL
      end

      # Run steamcmd with the given +commands.
      #
      # @param commands [Array<String>] steamcmd +commands (e.g. "+login", "anonymous")
      # @param dir [String] SteamCMD install dir
      # @return [Array(String, String, Process::Status)] stdout, stderr, status
      def run(*commands, dir: DEFAULT_DIR)
        script = ensure!(dir)
        Open3.capture3(script, *commands)
      end

      # Resolve the buildid published on a branch via +app_info_print.
      #
      # @param app [String, Integer] Steam app id
      # @param branch [String] branch name (default "public")
      # @param dir [String] SteamCMD install dir
      # @return [String] the resolved buildid
      # @raise [SteamCmdError] if the command fails or no buildid is found
      def resolve_build_id(app:, branch: "public", dir: DEFAULT_DIR)
        out, err, status = run("+login", "anonymous", "+app_info_print", app.to_s, "+quit", dir:)
        raise SteamCmdError, "steamcmd app_info_print #{app} failed: #{err.strip}" unless status.success?

        build_id = parse_build_id(out, branch)
        raise SteamCmdError, "no buildid for app #{app} branch #{branch} in app_info_print output" unless build_id

        build_id
      end

      # Parse the buildid for a branch out of app_info_print's VDF output. The
      # public-branch block holds only scalars (buildid, timeupdated, …), so a
      # non-greedy match up to the closing brace is enough to scope to the branch.
      #
      # @param output [String] raw app_info_print stdout
      # @param branch [String] branch name
      # @return [String, nil] the buildid, or nil if absent
      def parse_build_id(output, branch)
        match = output.match(/"#{Regexp.escape(branch)}"\s*\{[^}]*?"buildid"\s*"(\d+)"/m)
        match && match[1]
      end
    end
  end
end

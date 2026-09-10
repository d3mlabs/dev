# typed: strict
# frozen_string_literal: true

require "fileutils"
require "open3"
require "shellwords"
require_relative "../data_root"

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
      extend T::Sig

      class BootstrapError < StandardError; end
      class SteamCmdError < StandardError; end

      # Resolved through the data root (shared on agent-posture hosts).
      DEFAULT_DIR = T.let(Dev::DataRoot.expand("~/.dev/steamcmd"), String)
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
      sig { params(dir: String).returns(String) }
      def ensure!(dir = DEFAULT_DIR)
        script = File.join(dir, "steamcmd.sh")
        return script if File.executable?(script)

        FileUtils.mkdir_p(dir)
        url = download_url
        pipeline = "curl -fsSL #{url.shellescape} | tar -xz -C #{dir.shellescape}"
        Kernel.system("sh", "-c", pipeline) || Kernel.raise(BootstrapError, "failed to bootstrap SteamCMD from #{url}")
        Kernel.raise(BootstrapError, "SteamCMD bootstrap did not produce #{script}") unless File.executable?(script)

        script
      end

      # @return [String] the SteamCMD tarball URL for the host OS
      sig { returns(String) }
      def download_url
        RUBY_PLATFORM.include?("darwin") ? MACOS_URL : LINUX_URL
      end

      # Run steamcmd with the given +commands.
      #
      # @param commands [Array<String>] steamcmd +commands (e.g. "+login", "anonymous")
      # @param dir [String] SteamCMD install dir
      # @return [Array(String, String, Process::Status)] stdout, stderr, status
      sig { params(commands: String, dir: String).returns([String, String, Process::Status]) }
      def run(*commands, dir: DEFAULT_DIR)
        script = ensure!(dir)
        T.unsafe(Open3).capture3(script, *commands)
      end

      # Resolve every branch's current buildid via +app_info_print — one call
      # enumerates the whole branch universe.
      #
      # @param app [String, Integer] Steam app id
      # @param dir [String] SteamCMD install dir
      # @return [Hash{String => String}] branch name → current buildid
      # @raise [SteamCmdError] if the command fails
      sig { params(app: T.any(String, Integer), dir: String).returns(T::Hash[String, String]) }
      def resolve_branches(app:, dir: DEFAULT_DIR)
        out, err, status = run("+login", "anonymous", "+app_info_print", app.to_s, "+quit", dir:)
        Kernel.raise(SteamCmdError, "steamcmd app_info_print #{app} failed: #{err.strip}") unless status.success?

        parse_branches(out)
      end

      # Parse every branch's buildid out of app_info_print's VDF output. Each
      # branch block under "branches" holds only scalars (buildid,
      # timeupdated, …), so a bracket-free match per block is enough; branches
      # without a buildid (e.g. password-gated ones Steam redacts) are simply
      # absent from the result.
      #
      # @param output [String] raw app_info_print stdout
      # @return [Hash{String => String}] branch name → buildid
      sig { params(output: String).returns(T::Hash[String, String]) }
      def parse_branches(output)
        section = output[/"branches"\s*\{(.*)\z/m, 1] || ""
        section.scan(/"([^"]+)"\s*\{[^{}]*?"buildid"\s*"(\d+)"/m).to_h do |branch, build_id|
          [branch.to_s, build_id.to_s]
        end
      end
    end
  end
end

# typed: strict
# frozen_string_literal: true

require "fileutils"
require "pathname"
require_relative "../data_root"
require_relative "integration"
require_relative "steam_cmd"

module Dev
  module Deps
    # Lifecycle handler for Steam application dependencies (steam integration).
    #
    # Provisions a Steam app (the Satisfactory Dedicated Server) into its declared
    # install_dir on the host via SteamCMD, then mounts it into the build
    # container. Mirrors GhIntegration: a version-keyed install dir + marker
    # file, and deliberately bypasses the shared download Cache because the depot
    # is large (~15 GB) — the versioned install dir plus marker is the cache.
    #
    # The depot lands in install_dir/<buildid>/install (matching the /server
    # volume layout the integration harness expects, once dev's mount resolution
    # has appended the locked buildid). SteamCMD runs host-OS but forces the
    # depot platform (e.g. "linux") with +@sSteamCmdForcePlatformType, so a macOS
    # host can still provision the Linux server build.
    class SteamIntegration < Integration
      extend T::Sig

      class ProvisionError < StandardError; end
      class BuildMismatchError < StandardError; end

      MARKER_FILE = ".dev-steam-build"
      SERVER_SUBDIR = "install"

      # Provision all steam dependencies.
      #
      # @param dependencies [Array<Dependency>] steam deps to install
      sig { params(dependencies: T::Array[Dependency]).void }
      def install_all(dependencies)
        dependencies.each { |dep| install(dep) }
      end

      private

      # @param dep [Dependency]
      sig { params(dep: Dependency).void }
      def install(dep)
        base_dir = Pathname(Dev::DataRoot.expand(dep.metadata["install_dir"]))
        target_dir = versioned_dir(base_dir, dep.version)
        if version_published?(target_dir, MARKER_FILE, dep.version)
          puts ">>> #{dep.name}@#{dep.version} already installed at #{target_dir}"
          return
        end

        # Provision into staging on the same filesystem, then atomically publish
        # so a concurrent job never sees (or fights over) a half-downloaded depot.
        staging_dir = new_staging_dir(base_dir)
        server_dir = staging_dir / SERVER_SUBDIR
        FileUtils.mkdir_p(server_dir)

        puts ">>> Provisioning #{dep.name} (app #{dep.metadata["app"]}, build #{dep.version}) into #{target_dir}"
        provision(dep, server_dir)
        verify_build_id(dep, server_dir)

        (staging_dir / MARKER_FILE).write(dep.version)
        if publish_version(staging_dir, target_dir)
          puts ">>> Installed #{dep.name}@#{dep.version} to #{target_dir / SERVER_SUBDIR}"
        else
          puts ">>> #{dep.name}@#{dep.version} published concurrently at #{target_dir}"
        end
      ensure
        FileUtils.rm_rf(staging_dir) if staging_dir
      end

      # SteamCMD boundary. Isolated so tests can stub it. +force_install_dir must
      # precede +login (it binds the install dir for the session that follows),
      # and `validate` makes the step self-healing after an interrupted download.
      #
      # @param dep [Dependency]
      # @param server_dir [Pathname] depot install dir
      # @raise [ProvisionError] if SteamCMD fails
      sig { params(dep: Dependency, server_dir: Pathname).void }
      def provision(dep, server_dir)
        _out, err, status = SteamCmd.run(
          "+@sSteamCmdForcePlatformType", steam_platform_for(dep.metadata["platform"]),
          "+force_install_dir", server_dir.to_s,
          "+login", "anonymous",
          "+app_update", dep.metadata["app"], "validate",
          "+quit",
        )
        return if status.success?

        raise ProvisionError, "steamcmd app_update #{dep.metadata["app"]} failed: #{err.strip}"
      end

      # Map the declared platform (a dev platform name, riding the pin via the
      # declaration's materialization) to a SteamCMD ForcePlatformType value.
      # The mapping is this integration's vocabulary — the resolver and the
      # lockfile carry the declared name untranslated. The dedicated server is
      # Linux-only in our pipeline, so a missing platform defaults to "linux".
      #
      # @param platform [String, nil] declared platform (e.g. "LinuxServer")
      # @return [String] steam platform type ("linux" / "windows")
      sig { params(platform: T.nilable(String)).returns(String) }
      def steam_platform_for(platform)
        case platform
        when "LinuxServer" then "linux"
        when "WindowsServer", "Windows" then "windows"
        when nil then "linux"
        else platform.downcase
        end
      end

      # Confirm the installed depot matches the locked buildid. A mismatch means
      # the lock is stale (the public branch moved) — surface it so the user
      # re-runs dev update-deps rather than silently testing a different build.
      #
      # @param dep [Dependency]
      # @param server_dir [Pathname]
      # @raise [ProvisionError] if the appmanifest is missing
      # @raise [BuildMismatchError] if the installed buildid differs from the lock
      sig { params(dep: Dependency, server_dir: Pathname).void }
      def verify_build_id(dep, server_dir)
        manifest = server_dir / "steamapps" / "appmanifest_#{dep.metadata["app"]}.acf"
        raise ProvisionError, "appmanifest not found at #{manifest}" unless manifest.file?

        installed_build = manifest.read[/"buildid"\s*"(\d+)"/, 1]
        return if installed_build == dep.version

        raise BuildMismatchError,
          "#{dep.name}: expected buildid #{dep.version}, installed #{installed_build.inspect} " \
          "— run dev update-deps to re-pin"
      end
    end
  end
end

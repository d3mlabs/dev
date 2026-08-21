# frozen_string_literal: true

require "fileutils"
require "pathname"
require "rbconfig"
require_relative "integration"
require_relative "../deps"

module Dev
  module Deps
    # Lifecycle handler for the Cursor agent CLI (cursor_agent integration).
    #
    # Materializes the locked version into an immutable version-keyed subdir
    # of its declared install_dir (install_dir/<version>/, see Integration's
    # version-keyed layout) by downloading the same package the official
    # install script would — https://downloads.cursor.com/lab/<version>/… —
    # but pinned to the lock instead of whatever is latest. A `current`
    # symlink gives consumers (AI_FLOW_AGENT_BIN, PATH entries) a stable path
    # that survives version bumps.
    class CursorAgentIntegration < Integration
      class DownloadError < StandardError; end
      class ExtractionError < StandardError; end
      class UnsupportedArchitectureError < StandardError; end

      MARKER_FILE = ".dev-cursor-agent"

      # The served package URL scheme, as baked into the official install
      # script (CursorAgentRepository resolves the version from the same
      # script, so the pair drifts together or not at all).
      DOWNLOAD_URL_TEMPLATE = "https://downloads.cursor.com/lab/%{version}/%{os}/%{arch}/agent-cli-package.tar.gz"

      # uname-style CPU names → the scheme's arch segment.
      ARCHES = { "arm64" => "arm64", "aarch64" => "arm64", "x86_64" => "x64", "amd64" => "x64" }.freeze

      # Install all cursor_agent dependencies.
      #
      # @param dependencies [Array<Dependency>] cursor_agent deps to install
      def install_all(dependencies)
        dependencies.each { |dep| install(dep) }
      end

      private

      # @param dep [Dependency]
      def install(dep)
        base_dir = Pathname(File.expand_path(dep.metadata["install_dir"]))
        target_dir = versioned_dir(base_dir, dep.version)
        if version_published?(target_dir, MARKER_FILE, dep.version)
          puts ">>> #{dep.name}@#{dep.version} already installed at #{target_dir}"
          publish_current(base_dir, target_dir)
          return
        end

        # Staging lives next to the version dirs so the publish is a cheap
        # same-filesystem rename; a crashed run leaves published versions
        # intact.
        staging_dir = new_staging_dir(base_dir)
        package_dir = staging_dir / "package"
        archive_path = staging_dir / "agent-cli-package.tar.gz"
        FileUtils.mkdir_p(package_dir)

        puts ">>> Downloading #{dep.name}@#{dep.version}"
        download_package(package_url(dep.version), archive_path)
        extract_package(archive_path, package_dir)

        # Stamp the marker inside staging so the published dir is atomically
        # complete: a reader never sees content without a valid marker.
        (package_dir / MARKER_FILE).write(dep.version)
        if publish_version(package_dir, target_dir)
          puts ">>> Installed #{dep.name}@#{dep.version} to #{target_dir}"
        else
          puts ">>> #{dep.name}@#{dep.version} published concurrently at #{target_dir}"
        end
        publish_current(base_dir, target_dir)
      ensure
        FileUtils.rm_rf(staging_dir) if staging_dir
      end

      # The pinned package URL for this host.
      #
      # @param version [String] the locked version
      # @return [String]
      # @raise [UnsupportedArchitectureError] on a CPU the scheme has no
      #   package for
      def package_url(version)
        cpu = RbConfig::CONFIG["host_cpu"]
        arch = ARCHES[cpu]
        raise UnsupportedArchitectureError, "no cursor-agent package for #{cpu}" unless arch

        format(DOWNLOAD_URL_TEMPLATE, version: version, os: Deps.detect_host, arch: arch)
      end

      # Download the package archive. Isolated so tests can stub the network
      # boundary.
      #
      # @param url [String]
      # @param archive_path [Pathname] destination .tar.gz
      # @raise [DownloadError] if the download fails
      def download_package(url, archive_path)
        success = system("curl", "-fsSL", url, "-o", archive_path.to_s)
        return if success

        raise DownloadError, "cursor-agent download failed: #{url}"
      end

      # Extract the package, stripping its single top-level directory (the
      # official script's --strip-components=1) so cursor-agent lands at the
      # version dir root.
      #
      # @param archive_path [Pathname]
      # @param package_dir [Pathname]
      # @raise [ExtractionError] if tar fails
      def extract_package(archive_path, package_dir)
        success = system(
          "tar", "--strip-components=1", "-xzf", archive_path.to_s, "-C", package_dir.to_s
        )
        return if success

        raise ExtractionError, "cursor-agent extraction failed for #{archive_path}"
      end
    end
  end
end

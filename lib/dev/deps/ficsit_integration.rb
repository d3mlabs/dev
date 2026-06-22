# frozen_string_literal: true

require "digest"
require "fileutils"
require "tmpdir"
require_relative "integration"

module Dev
  module Deps
    # Lifecycle handler for ficsit.app mod dependencies (ficsit integration).
    #
    # Multi-arch: a single mod resolves to one or more platform targets
    # (Windows, LinuxServer, …) under metadata["platforms"], each with its own
    # { "hash", "link" }. install_all downloads and content-caches every locked
    # platform's zip, verifying SHA256 against the lock.
    #
    # Extraction into a game/server Mods/ directory is a consume-time concern:
    # a mod has more than one home (the Windows PC at deploy, the Linux server's
    # Mods/ in-container at integration test), so this integration only fills the
    # home-agnostic cache. Consumers pull the right platform's zip out via the
    # `dev deps path ficsit <mod> <platform>` accessor.
    class FicsitIntegration < Integration
      class MissingPlatformsError < StandardError; end
      class DownloadError < StandardError; end
      class IntegrityError < StandardError; end

      # Build the content-cache key for a locked mod platform. Shared with the
      # `dev deps path` accessor so consumers never reconstruct the key by hand.
      #
      # @param name [String] mod reference (e.g. "SML")
      # @param version [String] locked version (e.g. "3.12.0")
      # @param platform [String] ficsit target name (e.g. "LinuxServer")
      # @param hash [String] locked integrity hash ("SHA256=…")
      # @return [String] cache key, e.g. "ficsit/SML-3.12.0-LinuxServer-<sha>.zip"
      def self.cache_key(name:, version:, platform:, hash:)
        "ficsit/#{name}-#{version}-#{platform}-#{strip_algo(hash)}.zip"
      end

      # Strip the "SHA256=" algorithm prefix from a locked hash.
      #
      # @param hash [String, nil]
      # @return [String]
      def self.strip_algo(hash)
        hash.to_s.sub(/\ASHA256=/, "")
      end

      # Download and cache every locked platform zip for each ficsit dep.
      #
      # @param dependencies [Array<Dependency>] ficsit deps to install
      def install_all(dependencies)
        dependencies.each { |dep| install(dep) }
      end

      private

      # @param dep [Dependency]
      # @raise [MissingPlatformsError] if the dep was resolved without platforms
      def install(dep)
        platforms = dep.metadata["platforms"]
        if platforms.nil? || platforms.empty?
          raise MissingPlatformsError,
                "#{dep.name}@#{dep.version} has no resolved platforms — declare it in a " \
                "group with a platform and run dev update-deps"
        end

        platforms.each { |platform, target| install_platform(dep, platform, target) }
      end

      # @param dep [Dependency]
      # @param platform [String] ficsit target name
      # @param target [Hash] { "hash" => …, "link" => … }
      def install_platform(dep, platform, target)
        key = self.class.cache_key(name: dep.name, version: dep.version, platform:, hash: target["hash"])
        if cache.exists?(key)
          puts ">>> #{dep.name}@#{dep.version} (#{platform}) already cached"
          return
        end

        Dir.mktmpdir("dev-ficsit-fetch-") do |tmpdir|
          zip = File.join(tmpdir, "mod.zip")
          puts ">>> Downloading #{dep.name}@#{dep.version} (#{platform})"
          download(target["link"], zip)
          verify(zip, target["hash"], dep, platform)
          File.open(zip, "rb") { |file| cache.store(key, file) }
          puts ">>> Cached #{dep.name}@#{dep.version} (#{platform})"
        end
      end

      # @param link [String] absolute download URL
      # @param dest [String] destination path
      # @raise [DownloadError] if curl fails
      def download(link, dest)
        system("curl", "-fsSL", "-o", dest, link) ||
          raise(DownloadError, "download failed for #{link}")
      end

      # @param path [String] downloaded zip path
      # @param expected [String, nil] locked hash ("SHA256=…")
      # @param dep [Dependency] for error messages
      # @param platform [String] for error messages
      # @raise [IntegrityError] if the digest does not match
      def verify(path, expected, dep, platform)
        sha = self.class.strip_algo(expected)
        return if sha.empty?

        actual = Digest::SHA256.file(path).hexdigest
        return if actual == sha

        raise IntegrityError,
              "SHA256 mismatch for #{dep.name}@#{dep.version} (#{platform}): expected #{sha}, got #{actual}"
      end
    end
  end
end

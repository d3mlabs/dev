# frozen_string_literal: true

require "digest"
require "open3"
require "tempfile"
require_relative "repository"
require_relative "dependency"

module Dev
  module Deps
    # Fetches LuaRocks packages to exact version + SHA256.
    #
    # Uses `luarocks search <name> --porcelain` to find available versions,
    # picks the best match for the constraint, downloads the rock to compute
    # SHA256. Callers are responsible for caching.
    class LuaRocksRepository < Repository
      class SearchError < StandardError; end
      class NoVersionError < StandardError; end
      class DownloadError < StandardError; end

      # Resolve a LuaRocks package to an exact version + integrity hash.
      #
      # @param id [Hash] identifier with "name", "integration", "group", "constraint"
      # @return [Dependency]
      # @raise [SearchError] if luarocks search fails
      # @raise [NoVersionError] if no versions match
      # @raise [DownloadError] if luarocks download fails
      def fetch(id)
        name = id["name"]
        version = find_best_version(name, id["constraint"])
        rock_path = download_rock(name, version)
        sha256_hex = Digest::SHA256.file(rock_path).hexdigest
        hash = "SHA256=#{sha256_hex}"

        Dependency.new(
          name: name,
          integration: id["integration"].to_sym,
          group: id["group"].to_sym,
          version: version,
          hash: hash,
          metadata: { "downloaded_path" => rock_path },
        )
      end

      private

      # Find the best available version for a package.
      #
      # @param name [String] rock name
      # @param _constraint [String, nil] version constraint (not yet used)
      # @return [String] best matching version
      # @raise [SearchError] if luarocks search command fails
      # @raise [NoVersionError] if no versions found
      def find_best_version(name, _constraint)
        out, _err, status = Open3.capture3("luarocks", "search", name, "--porcelain")
        raise SearchError, "luarocks search #{name} failed" unless status.success?

        versions = out.scan(/^\s+(\S+)\s+\(/).map(&:first)
        raise NoVersionError, "No versions found for #{name}" if versions.empty?

        versions.first
      end

      # Download a source rock to a temp file.
      #
      # @param name [String] rock name
      # @param version [String] exact version
      # @return [String] path to downloaded rock file
      # @raise [DownloadError] if luarocks download command fails
      def download_rock(name, version)
        tmp = Tempfile.new(["dev_deps_#{name}", ".src.rock"])
        tmp.close
        _out, err, status = Open3.capture3(
          "luarocks", "download", name, version, "--source", "--to=#{File.dirname(tmp.path)}",
        )
        raise DownloadError, "luarocks download #{name} #{version} failed: #{err}" unless status.success?
        tmp.path
      end
    end
  end
end

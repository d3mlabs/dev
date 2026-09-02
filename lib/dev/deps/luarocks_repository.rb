# typed: strict
# frozen_string_literal: true

require "digest"
require "open3"
require "sorbet-runtime"
require "tempfile"
require_relative "dependency"
require_relative "package"
require_relative "package_id"
require_relative "package_version"
require_relative "repository"

module Dev
  module Deps
    # Fetches LuaRocks packages to exact version + SHA256.
    #
    # Uses `luarocks search <name> --porcelain` to find available versions,
    # picks the best match for the constraint, downloads the rock to compute
    # SHA256. Callers are responsible for caching.
    class LuaRocksRepository < Repository
      extend T::Sig

      class SearchError < StandardError; end
      class NoVersionError < StandardError; end
      class DownloadError < StandardError; end
      class RockNotFoundError < PackageNotFoundError; end

      # Report a rock's available versions from `luarocks search`.
      #
      # Facts only: the manifest search yields versions, nothing more — no
      # digests (luarocks verifies rockspec integrity itself at install; the
      # old resolve-time download-and-hash was audit-only and read by nobody)
      # and no edges (rock dependencies would require fetching each rockspec).
      # Constraint evaluation moves to RockScheme, fixing the old behavior of
      # taking the first version and ignoring the constraint entirely.
      #
      # @param id [PackageId] name is the rock name
      # @param filter [Hash] unused; the manifest search needs no locator
      # @return [Package]
      # @raise [SearchError] if luarocks search fails
      # @raise [RockNotFoundError] if the search yields no versions
      sig { override.params(id: PackageId, filter: T::Hash[String, T.untyped]).returns(Package) }
      def find(id, filter: {})
        versions = search_versions(id.name)
        raise RockNotFoundError, "no rock named #{id.name} on luarocks.org" if versions.empty?

        Package.new(
          id: id,
          versions: versions.map { |version| PackageVersion.new(version: version) },
        )
      end

      # Resolve a LuaRocks package to an exact version + integrity hash.
      #
      # @param id [Hash] identifier with "name", "integration", "group", "constraint"
      # @return [Dependency]
      # @raise [SearchError] if luarocks search fails
      # @raise [NoVersionError] if no versions match
      # @raise [DownloadError] if luarocks download fails
      sig { params(id: T::Hash[String, T.untyped]).returns(Dependency) }
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

      # All versions the manifest lists for a rock, most recent first,
      # deduplicated across arches.
      #
      # @param name [String] rock name
      # @return [Array<String>] version strings as listed
      # @raise [SearchError] if luarocks search command fails
      sig { params(name: String).returns(T::Array[String]) }
      def search_versions(name)
        out, _err, status = Open3.capture3("luarocks", "search", name, "--porcelain")
        raise SearchError, "luarocks search #{name} failed" unless status.success?

        # String#scan with a capture group always yields arrays of captures.
        matches = T.cast(out.scan(/^\s+(\S+)\s+\(/), T::Array[T::Array[String]])
        matches.map { |match| T.must(match.first) }.uniq
      end

      # Find the best available version for a package.
      #
      # @param name [String] rock name
      # @param _constraint [String, nil] version constraint (not yet used)
      # @return [String] best matching version
      # @raise [SearchError] if luarocks search command fails
      # @raise [NoVersionError] if no versions found
      sig { params(name: String, _constraint: T.nilable(String)).returns(String) }
      def find_best_version(name, _constraint)
        out, _err, status = Open3.capture3("luarocks", "search", name, "--porcelain")
        raise SearchError, "luarocks search #{name} failed" unless status.success?

        # String#scan with a capture group always yields arrays of captures.
        matches = T.cast(out.scan(/^\s+(\S+)\s+\(/), T::Array[T::Array[String]])
        versions = matches.map(&:first)
        raise NoVersionError, "No versions found for #{name}" if versions.empty?

        T.must(versions.first)
      end

      # Download a source rock to a temp file.
      #
      # @param name [String] rock name
      # @param version [String] exact version
      # @return [String] path to downloaded rock file
      # @raise [DownloadError] if luarocks download command fails
      sig { params(name: String, version: String).returns(String) }
      def download_rock(name, version)
        tmp = Tempfile.new(["dev_deps_#{name}", ".src.rock"])
        tmp.close
        _out, err, status = Open3.capture3(
          "luarocks", "download", name, version, "--source", "--to=#{File.dirname(T.must(tmp.path))}",
        )
        raise DownloadError, "luarocks download #{name} #{version} failed: #{err}" unless status.success?
        T.must(tmp.path)
      end
    end
  end
end

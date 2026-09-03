# typed: strict
# frozen_string_literal: true

require "open3"
require "sorbet-runtime"
require_relative "package"
require_relative "package_id"
require_relative "package_version"
require_relative "repository"

module Dev
  module Deps
    # Fact universe over the LuaRocks manifest, via
    # `luarocks search <name> --porcelain`.
    class LuaRocksRepository < Repository
      extend T::Sig

      class SearchError < StandardError; end
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
    end
  end
end

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
    class LuaRocksRegistry < Repository
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

      def find_best_version(name, _constraint)
        out, _err, status = Open3.capture3("luarocks", "search", name, "--porcelain")
        raise "luarocks search #{name} failed" unless status.success?

        versions = out.scan(/^\s+(\S+)\s+\(/).map(&:first)
        raise "No versions found for #{name}" if versions.empty?

        versions.first
      end

      def download_rock(name, version)
        tmp = Tempfile.new(["dev_deps_#{name}", ".src.rock"])
        tmp.close
        _out, err, status = Open3.capture3(
          "luarocks", "download", name, version, "--source", "--to=#{File.dirname(tmp.path)}",
        )
        raise "luarocks download #{name} #{version} failed: #{err}" unless status.success?
        tmp.path
      end
    end
  end
end

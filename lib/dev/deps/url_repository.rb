# frozen_string_literal: true

require "digest"
require "open3"
require "tempfile"
require_relative "repository"
require_relative "dependency"

module Dev
  module Deps
    # Fetches URL-based dependencies by downloading and computing SHA256.
    #
    # The artifact is downloaded to a temp file and hashed.
    # Callers (e.g. Integration) are responsible for caching the result.
    class UrlRepository < Repository
      def fetch(id)
        url = id["url"]
        name = id["name"]

        path = download_to_tempfile(url, name)
        sha256_hex = Digest::SHA256.file(path).hexdigest
        hash = "SHA256=#{sha256_hex}"

        Dependency.new(
          name: name,
          integration: id["integration"].to_sym,
          group: id["group"].to_sym,
          version: id["tag"],
          hash: hash,
          metadata: { "url" => url, "downloaded_path" => path },
        )
      end

      private

      def download_to_tempfile(url, name)
        tmp = Tempfile.new(["dev_deps_#{name}", ".bin"])
        tmp.binmode
        tmp.close

        _out, err, status = Open3.capture3("curl", "-fsSL", "-o", tmp.path, url)
        raise "Download failed for #{url}: #{err}" unless status.success?

        tmp.path
      end
    end
  end
end

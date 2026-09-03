# typed: strict
# frozen_string_literal: true

require "digest"
require "open3"
require "sorbet-runtime"
require "tempfile"
require_relative "artifact"
require_relative "package"
require_relative "package_id"
require_relative "package_version"
require_relative "repository"

module Dev
  module Deps
    # Fetches URL-based dependencies by downloading and computing SHA256.
    #
    # The artifact is downloaded to a temp file and hashed.
    # Callers (e.g. Integration) are responsible for caching the result.
    class UrlRepository < Repository
      extend T::Sig

      class DownloadError < StandardError; end

      # Report a URL dependency's universe: the one artifact behind the URL,
      # as a singleton.
      #
      # Dev-enforced integrity, trust-on-first-use: the artifact is downloaded
      # and hashed at resolve time, and that SHA256 rides as the version's
      # digest. The version is the filter's "tag"; URLs with no tag report an
      # empty version the Resolver mints back to nil.
      #
      # @param id [PackageId] source is the download URL
      # @param filter [Hash] locator: optionally "tag" for version
      # @return [Package] a singleton universe
      # @raise [DownloadError] if the download fails
      sig { override.params(id: PackageId, filter: T::Hash[String, T.untyped]).returns(Package) }
      def find(id, filter: {})
        url = T.must(id.source)
        path = download_to_tempfile(url, id.name)
        digest = "SHA256=#{Digest::SHA256.file(path).hexdigest}"

        Package.new(
          id: id,
          versions: [
            PackageVersion.new(
              version: filter["tag"].to_s,
              digest: digest,
              artifacts: { "default" => Artifact.new(uri: url, digest: digest) },
              metadata: { "url" => url, "downloaded_path" => path },
            ),
          ],
        )
      end

      private

      # Download a URL to a temp file via curl.
      #
      # @param url  [String] URL to download
      # @param name [String] dependency name (used in temp file naming)
      # @return [String] path to the downloaded temp file
      # @raise [DownloadError] if curl exits non-zero
      sig { params(url: String, name: String).returns(String) }
      def download_to_tempfile(url, name)
        tmp = Tempfile.new(["dev_deps_#{name}", ".bin"])
        tmp.binmode
        tmp.close

        _out, err, status = Open3.capture3("curl", "-fsSL", "-o", T.must(tmp.path), url)
        raise DownloadError, "Download failed for #{url}: #{err}" unless status.success?

        T.must(tmp.path)
      end
    end
  end
end

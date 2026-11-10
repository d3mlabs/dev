# typed: strict
# frozen_string_literal: true

require "json"
require "pathname"
require "uri"
require_relative "gh"
require_relative "release_tag"

module Dev
  module Lifecycle
    # The release archive on the forge (dev#192, K4): a GitHub release per
    # tag, carrying the archives as assets and `release.json` beside them.
    # The release *is* the archive of the cut — not a store (stores are
    # channels, K5) — so this is the one place dev writes one: created
    # once per tag, its assets uploaded with `--clobber` so a resumed run
    # replaces what a failed one half-attached — and the one place it is
    # read back from: `deploy --release` downloads the assets by name
    # (dev#425), and a publisher that points at an asset rather than
    # fetching it asks for its url (the brew formulas, dev#429). Reads and
    # writes go through Gh over the checkout, so the
    # repo is the one `origin` names and the credential the one gh holds.
    class GithubReleases
      extend T::Sig

      # Any failure of the release archive; the subclasses say which.
      class Error < RuntimeError; end

      # gh refused a read or a write; the message carries gh's words (a
      # tag the forge does not have, a token without `contents: write`).
      class ApiError < Error; end

      # gh answered with something that is not a release's url.
      class MalformedReleaseError < Error; end

      # The release carries no asset of the name asked for.
      class AssetMissingError < Error; end

      # What gh says when a tag has no release.
      NOT_FOUND = /release not found/i

      # gh matches `--pattern` as a glob (Go's `filepath.Match`), so an
      # asset name is escaped to match itself and nothing else.
      GLOB_METACHARACTERS = /[*?\[\\]/

      # @param gh [Gh] over the project's checkout
      sig { params(gh: Gh).void }
      def initialize(gh:)
        @gh = gh
      end

      # The release of a tag, if the forge has one.
      #
      # @param tag [ReleaseTag]
      # @return [URI, nil] the release's page; nil when none exists
      # @raise [ApiError]
      # @raise [Gh::GhMissingError]
      sig { params(tag: ReleaseTag).returns(T.nilable(URI::Generic)) }
      def find(tag)
        url(@gh.capture(["release", "view", tag.name, "--json", "url", "--jq", ".url"]))
      rescue Gh::CommandFailedError => e
        return nil if NOT_FOUND.match?(e.message)

        raise ApiError, e.message
      end

      # Create the release of a tag the forge already has (the cut pushed
      # it; `--verify-tag` refuses to mint one for a tag that is not there).
      #
      # @param tag [ReleaseTag]
      # @param title [String]
      # @param notes [String] the body, through stdin so it never hits argv
      # @return [URI] the release's page
      # @raise [ApiError]
      # @raise [Gh::GhMissingError]
      sig { params(tag: ReleaseTag, title: String, notes: String).returns(URI::Generic) }
      def create(tag, title:, notes:)
        url(@gh.capture(["release", "create", tag.name, "--title", title, "--notes-file", "-", "--verify-tag"], stdin: notes))
      rescue Gh::CommandFailedError => e
        raise ApiError, e.message
      end

      # Attach files to a tag's release, each under its file name,
      # replacing an asset of the same name.
      #
      # @param tag [ReleaseTag]
      # @param files [Array<Pathname>]
      # @return [void]
      # @raise [ApiError]
      # @raise [Gh::GhMissingError]
      sig { params(tag: ReleaseTag, files: T::Array[Pathname]).void }
      def upload(tag, files)
        return if files.empty?

        @gh.capture(["release", "upload", tag.name, *files.map(&:to_s), "--clobber"])
      rescue Gh::CommandFailedError => e
        raise ApiError, e.message
      end

      # Download assets of a tag's release by name into a directory, each
      # under its asset name, replacing a file of the same name — the
      # caller decides what is already there and worth keeping (a verified
      # download) and asks only for the rest.
      #
      # @param tag [ReleaseTag]
      # @param names [Array<String>] the assets' names, exactly
      # @param into [Pathname] the directory; created when missing
      # @return [void]
      # @raise [ApiError] a tag with no release, an asset not among the release's, a refused read
      # @raise [Gh::GhMissingError]
      sig { params(tag: ReleaseTag, names: T::Array[String], into: Pathname).void }
      def download(tag, names, into:)
        return if names.empty?

        into.mkpath
        @gh.capture(["release", "download", tag.name, "--dir", into.to_s, "--clobber", *names.flat_map { |name| ["--pattern", literal(name)] }])
      rescue Gh::CommandFailedError => e
        raise ApiError, e.message
      end

      # The public download url of one of a tag's release assets — what a
      # formula points at (dev#429): the forge's own statement of where
      # the asset is served, asked rather than spelled from the repo's
      # name, so dev carries no knowledge of GitHub's url layout.
      #
      # @param tag [ReleaseTag]
      # @param name [String] the asset's name, exactly
      # @return [URI]
      # @raise [AssetMissingError] a tag with no release, or one without the asset
      # @raise [ApiError]
      # @raise [MalformedReleaseError] gh answered without the asset's url
      # @raise [Gh::GhMissingError]
      sig { params(tag: ReleaseTag, name: String).returns(URI::Generic) }
      def asset_url(tag, name)
        assets = JSON.parse(@gh.capture(["release", "view", tag.name, "--json", "assets", "--jq", ".assets"]))
        asset = assets.find { |entry| entry["name"] == name }
        if asset.nil?
          raise AssetMissingError,
            "#{tag}'s release carries no asset #{name} (it carries: #{assets.map { |entry| entry["name"] }.join(", ")})"
        end

        url(asset["url"].to_s)
      rescue Gh::CommandFailedError => e
        raise AssetMissingError, "#{tag} has no release on the forge" if NOT_FOUND.match?(e.message)

        raise ApiError, e.message
      rescue JSON::ParserError => e
        raise MalformedReleaseError, "gh answered with something other than #{tag}'s assets: #{e.message}"
      end

      private

      # @param name [String] an asset's name
      # @return [String] the glob that matches exactly that name
      sig { params(name: String).returns(String) }
      def literal(name)
        name.gsub(GLOB_METACHARACTERS) { |char| "\\#{char}" }
      end

      # @param printed [String] what gh printed: the release's url
      # @return [URI]
      # @raise [MalformedReleaseError]
      sig { params(printed: String).returns(URI::Generic) }
      def url(printed)
        line = printed.strip
        raise MalformedReleaseError, "gh answered with no release url" if line.empty?

        URI.parse(line)
      rescue URI::InvalidURIError
        raise MalformedReleaseError, "gh answered with #{line.inspect}, which is not a release url"
      end
    end
  end
end

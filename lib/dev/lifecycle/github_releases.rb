# typed: strict
# frozen_string_literal: true

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
    # replaces what a failed one half-attached. Reads and writes go
    # through Gh over the checkout, so the repo is the one `origin` names
    # and the credential the one gh holds.
    class GithubReleases
      extend T::Sig

      # Any failure of the release archive; the subclasses say which.
      class Error < RuntimeError; end

      # gh refused a read or a write; the message carries gh's words (a
      # tag the forge does not have, a token without `contents: write`).
      class ApiError < Error; end

      # gh answered with something that is not a release's url.
      class MalformedReleaseError < Error; end

      # What gh says when a tag has no release.
      NOT_FOUND = /release not found/i

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

      private

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

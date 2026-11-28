# typed: strict
# frozen_string_literal: true

require "json"
require "pathname"
require "uri"
require_relative "gh"
require_relative "release_tag"
require_relative "../value_equality"

module Dev
  module Lifecycle
    # The release archive on the forge: a GitHub release per tag, carrying
    # the archives as assets and `release.json` beside them. Created once
    # per tag, its assets uploaded with `--clobber` so a resumed run
    # replaces what a failed one half-attached. Read back by `deploy
    # --release`, which downloads assets by name, and by a publisher that
    # points at an asset's url rather than fetching it. Reads and writes go
    # through Gh over the checkout.
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

      # A tag the forge has no release of, asked for its facts.
      class ReleaseMissingError < Error; end

      # The release is published on a repository with immutable releases:
      # its asset list froze at publish, so what it lacks it lacks for
      # good (dev#679).
      class FrozenError < Error
        extend T::Sig

        # @param tag [ReleaseTag]
        sig { params(tag: ReleaseTag).void }
        def initialize(tag)
          super("#{tag} is published and immutable: its assets were frozen at publish and cannot be completed — release the next version")
        end
      end

      # What the forge says of an upload onto a frozen release.
      FROZEN = /immutable release/i

      # A release the forge holds for a tag: its page, and whether it is
      # still a draft (created, assets attachable, not yet published).
      class Found < T::Struct
        extend T::Sig
        include Dev::ValueEquality::Derived

        const :url, URI::Generic
        const :draft, T::Boolean

        # @return [Array] the members that constitute identity
        sig { override.returns(T::Array[T.anything]) }
        def equality_members
          [url, draft]
        end
      end

      # What gh says when a tag has no release.
      NOT_FOUND = /release not found/i

      # What `gh api` says of a path the forge has nothing at.
      HTTP_NOT_FOUND = /HTTP 404/

      # `gh api`'s spelling of the checkout's repo: gh fills the
      # placeholders from `origin`, so dev resolves nothing itself.
      REPO_PATH = "repos/{owner}/{repo}"

      # Where the repository setting that freezes every release cut from
      # then on lives, for a message that names it.
      IMMUTABLE_RELEASES_SETTING = "Settings → General → Releases → Immutable releases"

      # A release's facts, as the forge holds them: whether it is
      # **immutable** — its tag, assets and existence frozen by the
      # repository's immutable-releases setting at creation, permanently
      # (only the notes and the latest designation stay editable), so a
      # head pointed at it cannot change under its readers — and whether it
      # is a pre-release.
      class Facts < T::Struct
        extend T::Sig
        include Dev::ValueEquality::Derived

        const :immutable, T::Boolean
        const :prerelease, T::Boolean

        # @return [Array] the members that constitute identity
        sig { override.returns(T::Array[T.anything]) }
        def equality_members
          [immutable, prerelease]
        end
      end

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
      # @return [Found, nil] the release's page and draft state; nil when none exists
      # @raise [ApiError]
      # @raise [MalformedReleaseError] gh answered with something other than a release
      # @raise [Gh::GhMissingError]
      sig { params(tag: ReleaseTag).returns(T.nilable(Found)) }
      def find(tag)
        release = JSON.parse(@gh.capture(["release", "view", tag.name, "--json", "url,isDraft"]))
        raise MalformedReleaseError, "gh answered with #{release.class}, not #{tag}'s release" unless release.is_a?(Hash)

        Found.new(url: url(release["url"].to_s), draft: release["isDraft"] == true)
      rescue Gh::CommandFailedError => e
        return nil if NOT_FOUND.match?(e.message)

        raise ApiError, e.message
      rescue JSON::ParserError => e
        raise MalformedReleaseError, "gh answered with something other than #{tag}'s release: #{e.message}"
      end

      # Create the release of a tag the forge already has (the cut pushed
      # it; `--verify-tag` refuses to mint one for a tag that is not there)
      # — as a **draft**. On a repository with immutable releases the
      # asset list freezes the moment a release is published, so the assets
      # go on first and {#publish} comes last (dev#679).
      #
      # @param tag [ReleaseTag]
      # @param title [String]
      # @param notes [String] the body, through stdin so it never hits argv
      # @return [URI] the release's page
      # @raise [ApiError]
      # @raise [Gh::GhMissingError]
      sig { params(tag: ReleaseTag, title: String, notes: String).returns(URI::Generic) }
      def create(tag, title:, notes:)
        url(@gh.capture(["release", "create", tag.name, "--title", title, "--notes-file", "-", "--verify-tag", "--draft"], stdin: notes))
      rescue Gh::CommandFailedError => e
        raise ApiError, e.message
      end

      # Publish a tag's draft: the assets are on, the list freezes complete.
      #
      # @param tag [ReleaseTag]
      # @param latest [Boolean] whether the forge may designate the release
      #   its latest; false where that designation is a head `deploy gh`
      #   moves (`--latest=false`: GitHub's own rule is "most recently
      #   created", and `release` moves no head)
      # @return [void]
      # @raise [ApiError]
      # @raise [Gh::GhMissingError]
      sig { params(tag: ReleaseTag, latest: T::Boolean).void }
      def publish(tag, latest:)
        argv = ["release", "edit", tag.name, "--draft=false"]
        argv << "--latest=false" unless latest
        @gh.capture(argv)
      rescue Gh::CommandFailedError => e
        raise ApiError, e.message
      end

      # A tag's release as the forge holds it: immutable or not, a
      # pre-release or not. Through the REST object, the one place the
      # immutability flag is reported.
      #
      # @param tag [ReleaseTag]
      # @return [Facts]
      # @raise [ReleaseMissingError] the tag has no release
      # @raise [ApiError]
      # @raise [MalformedReleaseError] gh answered with something other than a release
      # @raise [Gh::GhMissingError]
      sig { params(tag: ReleaseTag).returns(Facts) }
      def facts(tag)
        release = JSON.parse(@gh.capture(["api", "#{REPO_PATH}/releases/tags/#{tag.name}"]))
        raise MalformedReleaseError, "gh answered with #{release.class}, not #{tag}'s release" unless release.is_a?(Hash)

        # A forge that reports no flag (one without immutable releases)
        # has frozen nothing.
        Facts.new(immutable: release["immutable"] == true, prerelease: release["prerelease"] == true)
      rescue Gh::CommandFailedError => e
        raise ReleaseMissingError, "#{tag} has no release on the forge" if HTTP_NOT_FOUND.match?(e.message)

        raise ApiError, e.message
      rescue JSON::ParserError => e
        raise MalformedReleaseError, "gh answered with something other than #{tag}'s release: #{e.message}"
      end

      # Attach files to a tag's release, each under its file name,
      # replacing an asset of the same name.
      #
      # @param tag [ReleaseTag]
      # @param files [Array<Pathname>]
      # @return [void]
      # @raise [FrozenError] the release is published and immutable
      # @raise [ApiError]
      # @raise [Gh::GhMissingError]
      sig { params(tag: ReleaseTag, files: T::Array[Pathname]).void }
      def upload(tag, files)
        return if files.empty?

        @gh.capture(["release", "upload", tag.name, *files.map(&:to_s), "--clobber"])
      rescue Gh::CommandFailedError => e
        raise FrozenError.new(tag) if FROZEN.match?(e.message)

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

      # The names of a tag's release assets, as the forge lists them now —
      # what a cut reads back to see that every attach landed.
      #
      # @param tag [ReleaseTag]
      # @return [Array<String>]
      # @raise [AssetMissingError] a tag with no release
      # @raise [ApiError]
      # @raise [MalformedReleaseError] gh answered with something other than the assets
      # @raise [Gh::GhMissingError]
      sig { params(tag: ReleaseTag).returns(T::Array[String]) }
      def asset_names(tag)
        assets(tag).map { |entry| entry["name"].to_s }
      end

      # The public download url of one of a tag's release assets, as the
      # forge states it, so dev carries no knowledge of GitHub's url layout.
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
        listed = assets(tag)
        asset = listed.find { |entry| entry["name"] == name }
        if asset.nil?
          raise AssetMissingError,
            "#{tag}'s release carries no asset #{name} (it carries: #{listed.map { |entry| entry["name"] }.join(", ")})"
        end

        url(asset["url"].to_s)
      end

      private

      # A tag's release assets as gh lists them: one object per asset,
      # `name` and `url` among its fields.
      #
      # @param tag [ReleaseTag]
      # @return [Array<Hash>]
      # @raise [AssetMissingError] a tag with no release
      # @raise [ApiError]
      # @raise [MalformedReleaseError]
      # @raise [Gh::GhMissingError]
      sig { params(tag: ReleaseTag).returns(T::Array[T::Hash[String, T.untyped]]) }
      def assets(tag)
        listed = JSON.parse(@gh.capture(["release", "view", tag.name, "--json", "assets", "--jq", ".assets"]))
        raise MalformedReleaseError, "gh answered with #{listed.class}, not #{tag}'s assets" unless listed.is_a?(Array)

        listed
      rescue Gh::CommandFailedError => e
        raise AssetMissingError, "#{tag} has no release on the forge" if NOT_FOUND.match?(e.message)

        raise ApiError, e.message
      rescue JSON::ParserError => e
        raise MalformedReleaseError, "gh answered with something other than #{tag}'s assets: #{e.message}"
      end

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

# typed: strict
# frozen_string_literal: true

require "json"
require_relative "gh"
require_relative "github_releases"
require_relative "release_tag"
require_relative "series"
require_relative "../value_equality"

module Dev
  module Lifecycle
    # The gh channel's heads as the forge keeps them: one **series tag**
    # (`v1`, `v2`) per deployed series, pointing at the commit of the
    # release the series resolves to (`^1` in a lock, `@v1` in a
    # workflow), and GitHub's **latest designation**, the pointer for
    # whoever asks for the newest release.
    # `deploy gh` moves them (Deps::GhPublisher); `release` never does.
    # Reads and writes go through Gh over the checkout, so the repo is the
    # checkout's own and dev resolves nothing itself.
    #
    # One read tells everything: the forge's tag refs under `v` are the
    # series tags and the version tags `release` cuts, each at a commit,
    # so a pointer is named by the version tag at the same commit. A
    # series tag is lightweight and moved by force; an annotated tag's
    # ref names a tag object, not a commit, and is not read as a version.
    class GithubHeads
      extend T::Sig

      # Any failure of the heads; the subclasses say which.
      class Error < RuntimeError; end

      # gh refused a read or a write; the message carries gh's words (a
      # token without `contents: write`, a protected tag).
      class ApiError < Error; end

      # gh answered with something that is not a ref or a release.
      class MalformedAnswerError < Error; end

      # The ref namespace every tag lives in.
      TAGS = "refs/tags/"
      # Every tag ref beginning with the release prefix, in one listing.
      MATCHING_REFS = T.let("#{GithubReleases::REPO_PATH}/git/matching-refs/tags/#{ReleaseTag::PREFIX}".freeze, String)

      # One series' pointer: the tag and the commit it points at.
      class Pointer < T::Struct
        extend T::Sig
        include Dev::ValueEquality::Derived

        const :series, Series
        const :sha, String

        # @return [Array] the members that constitute identity
        sig { override.returns(T::Array[T.anything]) }
        def equality_members
          [series, sha]
        end
      end

      # Every head the repo keeps, read in one pass: the series pointers
      # in series order, the release tags at each commit (what a pointer
      # is at), and the latest designation.
      class Heads < T::Struct
        extend T::Sig
        include Dev::ValueEquality::Derived

        const :pointers, T::Array[Pointer]
        # @return [Hash{String => Array<ReleaseTag>}] commit → the release tags cut at it
        const :releases, T::Hash[String, T::Array[ReleaseTag]]
        const :latest, T.nilable(ReleaseTag)

        # The pointer of a series, if it has one.
        #
        # @param series [Series]
        # @return [Pointer, nil]
        sig { params(series: Series).returns(T.nilable(Pointer)) }
        def pointer(series)
          pointers.find { |pointer| pointer.series == series }
        end

        # The newest series with a pointer: the one whose head the latest
        # designation follows. nil when nothing is deployed yet.
        #
        # @return [Series, nil]
        sig { returns(T.nilable(Series)) }
        def newest_series
          pointers.map(&:series).max_by(&:major)
        end

        # The release tags cut at a commit — what a pointer there names.
        #
        # @param sha [String]
        # @return [Array<ReleaseTag>] empty when no release was cut there
        sig { params(sha: String).returns(T::Array[ReleaseTag]) }
        def releases_at(sha)
          releases.fetch(sha, [])
        end

        # @return [Array] the members that constitute identity
        sig { override.returns(T::Array[T.anything]) }
        def equality_members
          [pointers, releases, latest]
        end
      end

      # @param gh [Gh] over the project's checkout
      sig { params(gh: Gh).void }
      def initialize(gh:)
        @gh = gh
      end

      # Every head the repo keeps.
      #
      # @return [Heads]
      # @raise [ApiError]
      # @raise [MalformedAnswerError]
      # @raise [Gh::GhMissingError]
      sig { returns(Heads) }
      def read
        refs = tag_refs
        pointers = refs.filter_map do |name, sha|
          Pointer.new(series: Series.of_tag(name), sha:) if Series.tag?(name)
        end
        # Any other `v`-led tag naming a version is a release's; a tag
        # that is neither (`vendor-x`) is nobody's and not read.
        releases = refs.filter_map { |name, sha| [ReleaseTag.new(name.delete_prefix(ReleaseTag::PREFIX)), sha] if release_tag?(name) }
          .group_by { |_tag, sha| sha }
          .transform_values { |pairs| pairs.map { |tag, _sha| tag } }
        Heads.new(pointers: pointers.sort_by { |pointer| pointer.series.major }, releases:, latest:)
      end

      # Move a series tag to a commit, by force: the pointer follows the
      # deploy, forward or back.
      #
      # @param series [Series] a series with a pointer
      # @param sha [String] the release's commit
      # @return [void]
      # @raise [ApiError]
      # @raise [Gh::GhMissingError]
      sig { params(series: Series, sha: String).void }
      def point!(series, sha)
        write("#{GithubReleases::REPO_PATH}/git/refs/tags/#{series}", method: "PATCH", body: { "sha" => sha, "force" => true })
      end

      # Create a series tag at a commit: the series' first deploy.
      #
      # @param series [Series] a series with no pointer yet
      # @param sha [String] the release's commit
      # @return [void]
      # @raise [ApiError]
      # @raise [Gh::GhMissingError]
      sig { params(series: Series, sha: String).void }
      def create!(series, sha)
        write("#{GithubReleases::REPO_PATH}/git/refs", method: "POST", body: { "ref" => "#{TAGS}#{series}", "sha" => sha })
      end

      # Make a tag's release the repo's latest.
      #
      # @param tag [ReleaseTag]
      # @return [void]
      # @raise [ApiError]
      # @raise [Gh::GhMissingError]
      sig { params(tag: ReleaseTag).void }
      def designate_latest!(tag)
        @gh.capture(["release", "edit", tag.name, "--latest"])
      rescue Gh::CommandFailedError => e
        raise ApiError, "the latest designation could not be moved to #{tag}: #{e.message}"
      end

      private

      # Whether a tag name is a release's: `v` and a version, and not a
      # series tag (whose bare major is a version too).
      #
      # @param name [String] a tag name without its ref namespace
      # @return [Boolean]
      sig { params(name: String).returns(T::Boolean) }
      def release_tag?(name)
        !Series.tag?(name) && Series.version?(name.delete_prefix(ReleaseTag::PREFIX))
      end

      # Every tag ref under the release prefix that names a commit, as
      # `name → sha`. Paginated by gh; one ref per line through jq.
      #
      # @return [Hash{String => String}]
      # @raise [ApiError]
      # @raise [MalformedAnswerError]
      sig { returns(T::Hash[String, String]) }
      def tag_refs
        lines = @gh.capture(["api", "--paginate", MATCHING_REFS, "--jq", ".[]"]).lines(chomp: true).reject(&:empty?)
        lines.filter_map do |line|
          ref = JSON.parse(line)
          raise MalformedAnswerError, "gh listed #{ref.class}, not a ref" unless ref.is_a?(Hash)

          object = ref["object"]
          next unless object.is_a?(Hash) && object["type"] == "commit"

          [ref.fetch("ref").to_s.delete_prefix(TAGS), object.fetch("sha").to_s]
        end.to_h
      rescue Gh::CommandFailedError => e
        raise ApiError, "the tags could not be read: #{e.message}"
      rescue JSON::ParserError, KeyError => e
        raise MalformedAnswerError, "gh answered with something other than tag refs: #{e.message}"
      end

      # The release the forge designates latest, if it designates one.
      #
      # @return [ReleaseTag, nil]
      # @raise [ApiError]
      sig { returns(T.nilable(ReleaseTag)) }
      def latest
        name = @gh.capture(["release", "view", "--json", "tagName", "--jq", ".tagName"]).strip
        ReleaseTag.new(name.delete_prefix(ReleaseTag::PREFIX))
      rescue Gh::CommandFailedError => e
        return nil if GithubReleases::NOT_FOUND.match?(e.message)

        raise ApiError, "the latest designation could not be read: #{e.message}"
      end

      # One write, its body through stdin.
      #
      # @param path [String]
      # @param method [String]
      # @param body [Hash]
      # @return [void]
      # @raise [ApiError]
      sig { params(path: String, method: String, body: T::Hash[String, T.untyped]).void }
      def write(path, method:, body:)
        @gh.capture(["api", "-X", method, "--input", "-", path], stdin: JSON.generate(body))
      rescue Gh::CommandFailedError => e
        raise ApiError, "the head could not be moved: #{e.message}"
      end
    end
  end
end

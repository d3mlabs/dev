# typed: strict
# frozen_string_literal: true

require "json"

require "dev/lifecycle/release_tag"
require "dev/runner_setup"
require "dev/stream"

module Dev
  # Where a stream's head is — the question the job-started hook asks
  # before every job and `dev runner status` asks for its stream line.
  # The gh channel keeps its head per series as a pointer, the tag
  # `v<major>` (Lifecycle::HeadStrategy, pointed), which `dev deploy gh`
  # moves to a release's commit; so the head is read, never computed:
  # the series tag's commit, then the release tag of the series that names
  # that commit — the version word the tree is installed under, and what
  # a human reads as "what is live". A rolled-back head reads as the
  # earlier release, as it should: a follower wants what is deployed, not
  # the greatest tag (Lifecycle::Head).
  #
  # Three gh reads, no writes: the ref, the tag object when the ref is
  # annotated, the tags list. Over the same Executor seam every runner-side
  # gh read rides (RunnerSetup::Executor), so tests hand a fake.
  class StreamHeadLookup
    extend T::Sig

    # gh could not answer — offline, unauthenticated, refused — distinct
    # from a series that has no head.
    class QueryError < RuntimeError; end

    # The series tag does not exist: nothing of this series was deployed.
    class NoHeadError < RuntimeError; end

    # The series tag points at a commit no release tag of the series
    # names: the pointer was moved by hand, not by `dev deploy gh`.
    class HeadNotReleasedError < RuntimeError; end

    # A git object type as the refs API reports it.
    TAG_OBJECT = "tag"

    # @param executor [#capture] the gh CLI boundary (injectable for tests)
    sig { params(executor: T.untyped).void }
    def initialize(executor: RunnerSetup::Executor.new)
      @exec = executor
    end

    # The stream's head: the release its series tag points at.
    #
    # @param stream [Dev::Stream]
    # @return [Dev::Stream::Head]
    # @raise [NoHeadError] when the series tag does not exist
    # @raise [HeadNotReleasedError] when no release tag of the series names the commit
    # @raise [QueryError] when gh cannot be asked
    sig { params(stream: Stream).returns(Stream::Head) }
    def head(stream)
      commit = series_commit(stream)
      release = release_tags(stream).select { |_tag, sha| sha == commit }.keys.max_by { |tag| version_of(tag) }
      if release.nil?
        raise HeadNotReleasedError,
          "#{stream.head_tag} on #{stream.repo} points at #{commit[0, 12]}, which no #{stream.head_tag}.x release tag names — " \
            "move it with `dev deploy #{Stream::CHANNEL} --release <version>` in the project"
      end

      Stream::Head.new(version: version_of(release).to_s, commit: commit)
    end

    private

    # The commit the series tag points at, dereferenced when the tag is
    # annotated (the refs API then names the tag object, not its commit).
    #
    # @param stream [Dev::Stream]
    # @return [String] a commit SHA
    # @raise [NoHeadError]
    # @raise [QueryError]
    sig { params(stream: Stream).returns(String) }
    def series_commit(stream)
      out, err, ok = @exec.capture("gh", "api", "repos/#{stream.repo}/git/ref/tags/#{stream.head_tag}")
      unless ok
        if err.include?("HTTP 404")
          raise NoHeadError,
            "#{stream} has no head: #{stream.repo} has no #{stream.head_tag} tag — nothing of that series is deployed " \
              "(`dev deploy #{Stream::CHANNEL} --release <version>` in the project moves it)"
        end

        raise QueryError, "could not read #{stream.head_tag} on #{stream.repo}: #{err.strip}"
      end

      object = JSON.parse(out).fetch("object")
      sha = object.fetch("sha").to_s
      object.fetch("type") == TAG_OBJECT ? tag_object_commit(stream, sha) : sha
    end

    # @param stream [Dev::Stream]
    # @param sha [String] an annotated tag object's SHA
    # @return [String] the commit it tags
    # @raise [QueryError]
    sig { params(stream: Stream, sha: String).returns(String) }
    def tag_object_commit(stream, sha)
      out, err, ok = @exec.capture("gh", "api", "repos/#{stream.repo}/git/tags/#{sha}")
      raise QueryError, "could not read the tag object #{stream.head_tag} on #{stream.repo}: #{err.strip}" unless ok

      JSON.parse(out).fetch("object").fetch("sha").to_s
    end

    # The repo's release tags of the stream's series, each with the
    # commit it points at (the tags list dereferences annotated tags).
    #
    # @param stream [Dev::Stream]
    # @return [Hash{String => String}] tag name → commit SHA
    # @raise [QueryError]
    sig { params(stream: Stream).returns(T::Hash[String, String]) }
    def release_tags(stream)
      out, err, ok = @exec.capture("gh", "api", "--paginate", "repos/#{stream.repo}/tags", "--jq", '.[] | "\(.name) \(.commit.sha)"')
      raise QueryError, "could not list the tags of #{stream.repo}: #{err.strip}" unless ok

      out.each_line.filter_map do |line|
        tag, sha = line.split
        [tag, sha] if tag && sha && stream.includes_tag?(tag)
      end.to_h
    end

    # @param tag [String] a release tag, `v1.2.0`
    # @return [Gem::Version]
    sig { params(tag: String).returns(Gem::Version) }
    def version_of(tag)
      Gem::Version.new(tag.delete_prefix(Lifecycle::ReleaseTag::PREFIX))
    end
  end
end

# typed: strict
# frozen_string_literal: true

require "dev/lifecycle/channel"
require "dev/lifecycle/project_version"
require "dev/lifecycle/publisher_spec"
require "dev/lifecycle/release_tag"
require "dev/lifecycle/series"
require_relative "value_equality"

module Dev
  # A **stream**: what a slot's jobs run on when the project is a deployed
  # tool rather than a checkout — a repo's gh channel, followed on one
  # series. Spelled `<repo>@gh ~> <major>`: the constraint a host declares
  # the way an adopter's `uses: …@v<major>` does, this major and any minor
  # or patch, so a follower never crosses a major by following. The head
  # of a stream is the series tag `v<major>` the gh channel keeps per
  # series and `dev deploy gh` moves (Lifecycle::Series).
  #
  # Written by `dev runner register` from the declaring checkout — the
  # repo as GitHub spells it, the major from its VERSION — into each
  # slot's runner dir (StreamHook), read back by the job-started hook and
  # `dev runner status`. A build host anchors to its checkout and has no
  # stream.
  class Stream
    extend T::Sig
    include Dev::ValueEquality::Derived

    # A recorded word that is not `<owner/repo>@gh ~> <major>`.
    class MalformedError < ArgumentError; end

    # The one channel a stream follows: the gh channel's series pointer.
    CHANNEL = "gh"

    # How the constraint is spelled: the pessimistic operator on the major.
    CONSTRAINT = "~>"

    SPELLING = %r{\A(?<repo>[^\s/@]+/[^\s/@]+)@#{CHANNEL} #{Regexp.escape(CONSTRAINT)} (?<major>\d+)\z}

    # The head of a stream, as the channel points at it: the release
    # version the series tag names and the commit it sits on.
    class Head < T::Struct
      extend T::Sig
      include Dev::ValueEquality::Derived

      # @return [String] the release's version, `1.2.0`
      const :version, String

      # @return [String] the commit the series tag points at
      const :commit, String

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [version, commit]
      end

      # The release's tag — `v<version>` — which is also the version word
      # the gh tree is installed under.
      #
      # @return [String]
      sig { returns(String) }
      def tag
        Lifecycle::ReleaseTag.new(version).name
      end
    end

    # @return [String] "owner/repo", as GitHub spells it
    sig { returns(String) }
    attr_reader :repo

    # @return [Lifecycle::Series] the series followed
    sig { returns(Lifecycle::Series) }
    attr_reader :series

    class << self
      extend T::Sig

      # A stream from its spelling, as the runner dir records it.
      #
      # @param word [String] `owner/repo@gh ~> 1`
      # @return [Stream]
      # @raise [MalformedError]
      sig { params(word: String).returns(Stream) }
      def parse(word)
        match = SPELLING.match(word.strip)
        raise MalformedError, "#{word.inspect} is not a stream (owner/repo@#{CHANNEL} #{CONSTRAINT} <major>)" unless match

        new(repo: T.must(match[:repo]), series: Lifecycle::Series.new(Integer(T.must(match[:major]))))
      end

      # Whether a project is deployed through the gh channel — the one
      # channel a slot can follow. A `run:` child named gh is a script's
      # destination, not the channel.
      #
      # @param channels [Hash{String => Lifecycle::Channel}] the project's deploy channels
      # @return [Boolean]
      sig { params(channels: T::Hash[String, Lifecycle::Channel]).returns(T::Boolean) }
      def deployed_through_gh?(channels)
        channels.values.any? { |channel| channel.publisher == Lifecycle::PublisherSpec::Integration.new(name: CHANNEL) }
      end
    end

    # @param repo [String] "owner/repo"
    # @param series [Lifecycle::Series]
    sig { params(repo: String, series: Lifecycle::Series).void }
    def initialize(repo:, series:)
      @repo = repo
      @series = series
      freeze
    end

    # The series tag the channel keeps for this stream — its head's name
    # on gh.
    #
    # @return [String] `v<major>`
    sig { returns(String) }
    def head_tag
      @series.to_s
    end

    # The repo's name without its owner — what the installed tree is
    # called in the dependency vocabulary.
    #
    # @return [String]
    sig { returns(String) }
    def name
      T.must(@repo.split("/").last)
    end

    # Whether a tag is a release tag of this series: `v<major.minor.patch>`
    # as `dev release` cuts them, with this major — never the series tag
    # itself, never a prerelease (a follower installs releases).
    #
    # @param tag [String] a tag name as the repo spells it
    # @return [Boolean]
    sig { params(tag: String).returns(T::Boolean) }
    def includes_tag?(tag)
      return false unless tag.start_with?(Lifecycle::ReleaseTag::PREFIX)

      version = tag.delete_prefix(Lifecycle::ReleaseTag::PREFIX)
      Lifecycle::ProjectVersion::SEMVER.match?(version) && @series.includes?(version)
    end

    # The stream's spelling, as recorded and as reported.
    #
    # @return [String] `owner/repo@gh ~> 1`
    sig { returns(String) }
    def to_s
      "#{@repo}@#{CHANNEL} #{CONSTRAINT} #{@series.major}"
    end

    # @return [Array] the members that constitute identity
    sig { override.returns(T::Array[T.anything]) }
    def equality_members
      [@repo, @series]
    end
  end
end

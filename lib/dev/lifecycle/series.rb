# typed: strict
# frozen_string_literal: true

require_relative "../value_equality"
require_relative "release_tag"

module Dev
  module Lifecycle
    # A release **series**: every version of one major, named `v<major>`
    # as the plan names a series tag. What a follower is on — a host on
    # `~> 1`, an adopter on `@v1` — and what a head is kept per: a pointed
    # channel holds one pointer per series, a derived channel's head within
    # a series is the greatest non-prerelease version of that major
    # (Head.derive). A major is never crossed by following: a 2.0.0 deploy
    # moves `v2` and leaves every follower of `v1` where it was.
    #
    # The major is semver's, whatever the version's own spelling: under
    # 0.x the minor is the breaking unit, and the series is still `v0`,
    # so "series = major" holds across channels.
    #
    # Owns the invariant that a major is a count: a negative one names
    # nothing.
    class Series
      extend T::Sig
      include Dev::ValueEquality::Derived

      # A word that is not a version has no major and so no series.
      class NotAVersionError < ArgumentError; end

      # A major below zero.
      class NegativeMajorError < ArgumentError; end

      # A tag that is not a series tag (`v1.2.0`, `latest`).
      class NotASeriesTagError < ArgumentError; end

      # The name of a series tag: `v<major>`, nothing after the major — the
      # one spelling a pointed channel keeps its per-series pointer under
      # and every reader of a forge's tags tells a pointer from a version by.
      TAG_PATTERN = /\A#{ReleaseTag::PREFIX}(\d+)\z/

      # @return [Integer] the major every version of the series shares
      sig { returns(Integer) }
      attr_reader :major

      class << self
        extend T::Sig

        # Whether a tag name is a series tag (`v1`), as opposed to a
        # release's (`v1.2.0`) or anything else.
        #
        # @param tag [String] a tag name without its ref namespace
        # @return [Boolean]
        sig { params(tag: String).returns(T::Boolean) }
        def tag?(tag)
          TAG_PATTERN.match?(tag)
        end

        # The series a series tag names.
        #
        # @param tag [String] a tag name (`v1`)
        # @return [Series]
        # @raise [NotASeriesTagError]
        sig { params(tag: String).returns(Series) }
        def of_tag(tag)
          major = TAG_PATTERN.match(tag)&.[](1)
          raise NotASeriesTagError, "#{tag.inspect} is not a series tag (v<major>)" if major.nil?

          new(Integer(major))
        end

        # Whether a word is a version with a major: digit-led and readable
        # by Gem::Version's tolerant grammar (Gem::Version reads the empty
        # string as 0, so digit-led is checked first). A tag's `v` prefix
        # is the publisher's to strip; `v1.2.0` is not a version here.
        #
        # @param word [String]
        # @return [Boolean]
        sig { params(word: String).returns(T::Boolean) }
        def version?(word)
          word.match?(/\A\d/) && Gem::Version.correct?(word)
        end

        # The series a version belongs to.
        #
        # @param version [String] a version word as its store spells it (`1.2.0`, `1.0.0-rc.1`)
        # @return [Series]
        # @raise [NotAVersionError]
        sig { params(version: String).returns(Series) }
        def of(version)
          raise NotAVersionError, "#{version.inspect} is not a version, so it belongs to no series" unless version?(version)

          # A digit-led version's first segment is always the Integer major.
          new(T.cast(Gem::Version.new(version).segments.fetch(0), Integer))
        end
      end

      # @param major [Integer] zero or more
      # @raise [NegativeMajorError]
      sig { params(major: Integer).void }
      def initialize(major)
        raise NegativeMajorError, "a series is a major, zero or more: #{major}" if major.negative?

        @major = major
        freeze
      end

      # Whether a version is of this series.
      #
      # @param version [String] a version word
      # @return [Boolean]
      # @raise [NotAVersionError]
      sig { params(version: String).returns(T::Boolean) }
      def includes?(version)
        self.class.of(version) == self
      end

      # The series' name, `v<major>`: the plan's spelling of a series and
      # the tag a pointed channel keeps per series.
      #
      # @return [String]
      sig { returns(String) }
      def to_s
        "#{ReleaseTag::PREFIX}#{@major}"
      end

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [@major]
      end
    end
  end
end

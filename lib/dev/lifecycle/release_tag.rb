# typed: strict
# frozen_string_literal: true

module Dev
  module Lifecycle
    # The name a release carries on the forge (dev#192, K4, K6): the git
    # tag `v<version>` that `release <version>` cuts (dev#424) and that a
    # deploy of the release's archives is recorded against as its `ref`
    # (`deploy --release <version>`, dev#425) — which is how `dev deploy
    # status --release <version>` finds, per channel, what carries it. One
    # spelling of the tag for every surface that names a release.
    #
    # Owns the invariant that a version is a word: an empty one would tag
    # nothing, a spaced one is not a ref.
    class ReleaseTag
      extend T::Sig

      # A version that cannot name a tag.
      class InvalidVersionError < ArgumentError; end

      PREFIX = "v"
      VERSION_PATTERN = /\A[^\s\/]+\z/

      # @return [String] the version as given, without the prefix
      sig { returns(String) }
      attr_reader :version

      # @param version [String] the release's version (`1.2.0`)
      # @raise [InvalidVersionError]
      sig { params(version: String).void }
      def initialize(version)
        unless VERSION_PATTERN.match?(version)
          raise InvalidVersionError, "#{version.inspect} cannot name a release: a version is one word (1.2.0)"
        end

        @version = version
        freeze
      end

      # The tag's name, the release's `ref` on the forge.
      #
      # @return [String] `v<version>`
      sig { returns(String) }
      def name
        "#{PREFIX}#{@version}"
      end

      sig { returns(String) }
      def to_s
        name
      end

      sig { params(other: Object).returns(T::Boolean) }
      def ==(other)
        other.is_a?(ReleaseTag) && @version == other.version
      end

      sig { params(other: Object).returns(T::Boolean) }
      def eql?(other)
        self == other
      end

      sig { returns(Integer) }
      def hash
        [ReleaseTag, @version].hash
      end
    end
  end
end

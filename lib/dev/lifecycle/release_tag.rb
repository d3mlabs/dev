# typed: strict
# frozen_string_literal: true

require_relative "../value_equality"

module Dev
  module Lifecycle
    # The name a release carries on the forge: the git tag `v<version>`
    # that `release` cuts and that a deploy of the release's archives is
    # recorded against as its `ref`. One spelling of the tag for every
    # surface that names a release.
    #
    # Owns the invariant that a version is a word: an empty one would tag
    # nothing, a spaced one is not a ref.
    class ReleaseTag
      extend T::Sig
      include Dev::ValueEquality::Derived

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

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [@version]
      end
    end
  end
end

# typed: strict
# frozen_string_literal: true

module Dev
  module Deps
    # A single downloadable file that dev itself fetches.
    #
    # Artifacts exist only for ecosystems where dev does the downloading
    # (ficsit target zips, gh release assets, url tarballs). Tool-mediated
    # ecosystems have none: bundler fetches its own gems, so a bundler
    # PackageVersion carries an empty artifact set rather than nil-stuffed
    # placeholder entries.
    #
    # The digest here is an *enforcement input*: dev verifies downloaded bytes
    # against it and keys the download cache with it. A nil digest has exactly
    # one meaning — upstream publishes none — and is computed trust-on-first-use
    # at fetch time. See the integrity regimes section of
    # docs/deps-architecture.md for who enforces what, and where.
    class Artifact
      extend T::Sig

      # The artifact has no URI, so dev cannot locate the bytes.
      class MissingUriError < StandardError; end

      # @return [String] where the bytes live
      sig { returns(String) }
      attr_reader :uri

      # @return [String, nil] published integrity digest ("SHA256=…"), or nil
      #   when upstream publishes none
      sig { returns(T.nilable(String)) }
      attr_reader :digest

      # The uri parameter is typed nilable because artifacts are built from
      # backing-service payloads (registry JSON, GraphQL responses) where the
      # field can be absent — validating it here is boundary coercion, not
      # defensive programming against internal callers.
      #
      # @param uri [String, nil] where the bytes live
      # @param digest [String, nil] published integrity digest, if any
      # @raise [MissingUriError] if uri is missing or blank
      sig { params(uri: T.nilable(String), digest: T.nilable(String)).void }
      def initialize(uri:, digest: nil)
        raise MissingUriError, "an artifact without a uri cannot be fetched" if uri.nil? || uri.empty?

        @uri = T.let(uri, String)
        @digest = digest
        freeze
      end

      # @param other [Object]
      # @return [Boolean] whether other describes the same bytes
      sig { params(other: T.untyped).returns(T::Boolean) }
      def ==(other)
        return false unless other.is_a?(Artifact)

        [uri, digest] == [other.uri, other.digest]
      end
      alias_method :eql?, :==

      # @return [Integer] hash code
      sig { returns(Integer) }
      def hash
        [self.class, uri, digest].hash
      end
    end
  end
end

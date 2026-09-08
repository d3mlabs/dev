# typed: strict
# frozen_string_literal: true

require_relative "version_scheme"

module Dev
  module Deps
    # Exact-coordinate constraint semantics (:gh tags): the constraint names
    # one version, and a candidate satisfies it by being that version.
    #
    # These ecosystems have no range grammar — a GitHub tag is an exact ask
    # by design, selecting one version out of the enumerated universe.
    class ExactScheme < VersionScheme
      extend T::Sig

      # @return [String] the constraint key carrying the exact coordinate
      sig { returns(String) }
      attr_reader :key

      # @param key [String] the constraint key this ecosystem pins with
      #   (e.g. "tag" for gh, "version" for xcode)
      sig { params(key: String).void }
      def initialize(key:)
        @key = key
      end

      # @param version [PackageVersion] a candidate version
      # @param constraint [Hash] declaration constraint; key names the coordinate
      # @return [Boolean] true when unconstrained or the coordinate matches
      sig { override.params(version: PackageVersion, constraint: T::Hash[String, T.untyped]).returns(T::Boolean) }
      def satisfies?(version, constraint)
        pinned = constraint[key]
        pinned.nil? || pinned.to_s == version.version
      end

      # @param versions [Array<String>] reported versions
      # @return [Array<String>] the same versions, order untouched — exact
      #   coordinates carry no order to impose
      sig { override.params(versions: T::Array[String]).returns(T::Array[String]) }
      def sort(versions)
        versions.dup
      end
    end
  end
end

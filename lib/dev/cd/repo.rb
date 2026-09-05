# typed: strict
# frozen_string_literal: true

require "pathname"

module Dev
  module Cd
    # A discovered git checkout under the search root.
    #
    # A plain value class rather than Data.define: Sorbet at strict demands
    # sigs on the readers Data.define synthesizes, and re-declaring them in
    # the define block would destroy the originals (the same conversion
    # Clone::RepoSpec already made).
    class Repo
      extend T::Sig

      # @return [Pathname] absolute Pathname of the repo root
      sig { returns(Pathname) }
      attr_reader :path

      # Path segments relative to the search root
      # (e.g. ["github.com", "d3mlabs", "dev"]); queries are matched
      # right-anchored against them, so the last segment is the repo name.
      #
      # @return [Array<String>]
      sig { returns(T::Array[String]) }
      attr_reader :segments

      # @param path [Pathname, String] absolute path of the repo root
      # @param segments [Array<String>] path segments relative to the search root
      sig { params(path: T.any(Pathname, String), segments: T::Array[String]).void }
      def initialize(path:, segments:)
        @path = T.let(Pathname(path), Pathname)
        @segments = T.let(segments.map(&:to_s).freeze, T::Array[String])
      end

      # The repo's leaf name (last path segment).
      #
      # @return [String]
      sig { returns(String) }
      def name
        segments.fetch(-1)
      end

      # The trailing segments rendered as a query-shaped suffix.
      #
      # @param depth [Integer] how many trailing segments to include
      # @return [String] e.g. "d3mlabs/dev" for depth 2
      sig { params(depth: Integer).returns(String) }
      def suffix(depth)
        segments.last(depth).join("/")
      end
    end
  end
end

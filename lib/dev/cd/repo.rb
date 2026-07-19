# frozen_string_literal: true

require "pathname"

module Dev
  module Cd
    # A discovered git checkout under the search root.
    #
    # - path:     absolute Pathname of the repo root
    # - segments: path segments relative to the search root
    #   (e.g. ["github.com", "d3mlabs", "dev"]); queries are matched
    #   right-anchored against them, so the last segment is the repo name.
    Repo = Data.define(:path, :segments) do
      def initialize(path:, segments:)
        super(path: Pathname(path), segments: segments.map(&:to_s).freeze)
      end

      # The repo's leaf name (last path segment).
      #
      # @return [String]
      def name
        segments.fetch(-1)
      end

      # The trailing segments rendered as a query-shaped suffix.
      #
      # @param depth [Integer] how many trailing segments to include
      # @return [String] e.g. "d3mlabs/dev" for depth 2
      def suffix(depth)
        segments.last(depth).join("/")
      end
    end
  end
end

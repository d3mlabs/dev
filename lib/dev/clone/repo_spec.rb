# frozen_string_literal: true

require "pathname"

module Dev
  module Clone
    # The parsed target of a `dev clone` invocation.
    #
    # Accepts "<repo>" (org defaults to d3mlabs) or "<org>/<repo>". The host
    # is always github.com — clones ride the user's gh auth, and the
    # canonical checkout layout under the search root is host/org/repo.
    #
    # A plain value class rather than Data.define: constants declared inside
    # a define block land on the enclosing module (breaking the nested typed
    # error), and Sorbet rejects the `class X < Data.define` form.
    class RepoSpec
      # The argument is not a "<repo>" or "<org>/<repo>" clone target.
      class MalformedRepoError < RuntimeError; end

      DEFAULT_ORG = "d3mlabs"
      HOST = "github.com"

      # GitHub owner/repo name characters: word chars, dots, hyphens.
      SEGMENT_PATTERN = /\A[\w.-]+\z/

      # @return [String]
      attr_reader :org, :name

      class << self
        # Parse a clone target argument into a spec.
        #
        # @param arg [String] "<repo>" or "<org>/<repo>"
        # @return [Dev::Clone::RepoSpec]
        # @raise [MalformedRepoError] when the argument is not one or two
        #   valid path segments
        def parse(arg)
          # -1 keeps trailing empty segments, so "repo/" fails validation
          # instead of silently collapsing to "repo".
          segments = arg.split("/", -1)
          unless (1..2).cover?(segments.size) && segments.all? { |segment| segment.match?(SEGMENT_PATTERN) }
            raise MalformedRepoError, "expected <repo> or <org>/<repo>, got '#{arg}'"
          end

          org, name = segments.size == 2 ? segments : [DEFAULT_ORG, segments.fetch(0)]
          new(org:, name:)
        end
      end

      # @param org [String] the GitHub owner
      # @param name [String] the repo name
      def initialize(org:, name:)
        @org = org
        @name = name
      end

      # The gh clone target.
      #
      # @return [String] "org/repo"
      def full_name
        "#{org}/#{name}"
      end

      # The canonical checkout location relative to the search root.
      #
      # @return [Pathname] "github.com/<org>/<repo>"
      def relative_path
        Pathname(HOST) / org / name
      end
    end
  end
end

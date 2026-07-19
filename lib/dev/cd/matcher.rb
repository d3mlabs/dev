# frozen_string_literal: true

require "dev/cd/repo"

module Dev
  module Cd
    # Fuzzy matching of a query against discovered repos.
    #
    # The query is a right-anchored path suffix matched per segment: `dev`
    # matches the leaf, `d3mlabs/dev` matches org+leaf, `github.com/d3mlabs/dev`
    # matches host+org+leaf. Each segment matches independently and
    # case-insensitively — exact beats prefix beats substring — so `d3m/d`
    # finds `d3mlabs/dev`. Ties sort by path, keeping ambiguous candidate
    # lists reproducible regardless of filesystem walk order.
    class Matcher
      # No repo matched the query.
      class RepoNotFoundError < StandardError
        # @param query [String]
        def initialize(query)
          super("no repo matching '#{query}' found")
        end
      end

      # Multiple repos matched the query equally well; carries the rendered
      # candidates so callers can print them and hint at a deeper suffix.
      class AmbiguousRepoError < StandardError
        # @return [Array<String>] candidates at their shortest-unique depth
        attr_reader :candidates

        # @param query [String]
        # @param candidates [Array<String>]
        def initialize(query, candidates)
          @candidates = candidates
          super("'#{query}' is ambiguous (#{candidates.size} matches)")
        end
      end

      EXACT_SCORE = 3
      PREFIX_SCORE = 2
      SUBSTRING_SCORE = 1

      # @param repos [Array<Dev::Cd::Repo>] the discovered candidate set
      def initialize(repos:)
        @repos = repos.sort_by { |repo| repo.path.to_s }
      end

      # Resolve a query to exactly one repo.
      #
      # When several repos match, the best-scoring one wins only if it is
      # strictly better; equal-best matches are ambiguous, never guessed.
      #
      # @param query [String]
      # @return [Dev::Cd::Repo]
      # @raise [RepoNotFoundError] when nothing matches
      # @raise [AmbiguousRepoError] when the best matches tie
      def resolve(query)
        scored = scored_matches(query)
        raise RepoNotFoundError, query if scored.empty?

        best_score = scored.fetch(0).fetch(1)
        best = scored.take_while { |_repo, score| score == best_score }.map(&:first)
        return best.fetch(0) if best.size == 1

        raise AmbiguousRepoError.new(query, best.map { |repo| render(repo) })
      end

      # Ranked candidates for a (possibly partial) query, each rendered at its
      # shortest-unique depth. An empty query lists every repo.
      #
      # @param query [String]
      # @return [Array<String>]
      def candidates(query)
        scored_matches(query).map { |repo, _score| render(repo) }
      end

      # Render a repo at the shortest suffix depth that is unique across the
      # whole candidate set, so the rendered form always resolves uniquely
      # (two `dev` repos render as `<org>/dev`; the same org/repo under two
      # hosts renders as `<host>/<org>/<repo>`).
      #
      # @param repo [Dev::Cd::Repo]
      # @return [String]
      def render(repo)
        (1..repo.segments.size).each do |depth|
          suffix = repo.suffix(depth)
          return suffix if @repos.one? { |other| other.suffix(depth) == suffix }
        end
        repo.suffix(repo.segments.size)
      end

      private

      # All matching repos with their combined scores, best first (ties by
      # path, which @repos is already sorted by).
      #
      # @param query [String]
      # @return [Array<Array(Dev::Cd::Repo, Integer)>]
      def scored_matches(query)
        query_segments = query.split("/").reject(&:empty?)
        @repos
          .filter_map do |repo|
            score = score(query_segments, repo)
            [repo, score] if score
          end
          .sort_by.with_index { |(_repo, score), index| [-score, index] }
      end

      # Combined match score for a repo, or nil when it doesn't match. Query
      # segments are matched right-anchored against the repo's segments; each
      # must match its counterpart. An empty query matches everything.
      #
      # @param query_segments [Array<String>]
      # @param repo [Dev::Cd::Repo]
      # @return [Integer, nil]
      def score(query_segments, repo)
        return 0 if query_segments.empty?
        return nil if query_segments.size > repo.segments.size

        tail = repo.segments.last(query_segments.size)
        scores = query_segments.zip(tail).map { |wanted, actual| segment_score(wanted, actual) }
        return nil if scores.any?(&:nil?)

        scores.sum
      end

      # Score one query segment against one path segment (case-insensitive):
      # exact > prefix > substring > no match (nil).
      #
      # @param wanted [String] the query segment
      # @param actual [String] the repo path segment
      # @return [Integer, nil]
      def segment_score(wanted, actual)
        wanted = wanted.downcase
        actual = actual.downcase
        return EXACT_SCORE if actual == wanted
        return PREFIX_SCORE if actual.start_with?(wanted)
        return SUBSTRING_SCORE if actual.include?(wanted)

        nil
      end
    end
  end
end

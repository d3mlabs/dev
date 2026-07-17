# frozen_string_literal: true

require "pathname"
require "dev/cd/repo"
require "dev/cd/repo_index"

module Dev
  module Cd
    # Fuzzy-matches a query against discovered checkouts.
    #
    # Ranking per segment: exact > prefix > substring (case-insensitive).
    # Multi-segment queries (`org/repo`, or a longer path suffix under the
    # search root) score each segment independently and combine them.
    class Matcher
      # No checkout matched the query.
      class RepoNotFoundError < StandardError; end

      # Several checkouts tied for the best score; do not guess.
      class AmbiguousRepoError < StandardError
        # @return [Array<Dev::Cd::Repo>]
        attr_reader :candidates

        # @param message [String]
        # @param candidates [Array<Dev::Cd::Repo>]
        def initialize(message, candidates:)
          super(message)
          @candidates = candidates
        end
      end

      MAX_AMBIGUOUS = 10

      # Score values — higher is better. Gaps keep combined totals ordered so
      # exact-on-both-sides outranks any mixed exact/prefix/substring pair.
      SCORE_EXACT = 3
      SCORE_PREFIX = 2
      SCORE_SUBSTRING = 1

      # @param index [Dev::Cd::RepoIndex]
      def initialize(index:)
        @index = index
      end

      # Resolve a query to a single checkout path.
      #
      # @param query [String]
      # @return [Pathname]
      # @raise [RepoNotFoundError] when nothing matches
      # @raise [AmbiguousRepoError] when multiple repos share the best score
      def resolve(query)
        ranked = rank(query)
        raise RepoNotFoundError, "dev: no repo matching #{query.inspect} under #{@index.root}" if ranked.empty?

        best_score = ranked.first.fetch(:score)
        best = ranked.select { |entry| entry.fetch(:score) == best_score }.map { |entry| entry.fetch(:repo) }
        return best.first.path if best.length == 1

        listed = best.first(MAX_AMBIGUOUS).map(&:org_repo)
        suffix = best.length > MAX_AMBIGUOUS ? "\n  … and #{best.length - MAX_AMBIGUOUS} more" : ""
        raise AmbiguousRepoError.new(
          "dev: ambiguous repo #{query.inspect}; candidates:\n#{listed.map { |c| "  #{c}" }.join("\n")}#{suffix}",
          candidates: best,
        )
      end

      # Completion candidates for a typed prefix.
      #
      # Unique leaf names are offered as the short form; ambiguous leaves are
      # offered only as `org/repo`. When the prefix contains `/`, only
      # `org/repo` (and longer relative-path) forms are considered.
      #
      # @param prefix [String]
      # @return [Array<String>] sorted, deduplicated candidate strings
      def complete(prefix)
        prefix = prefix.to_s
        repos = @index.all
        leaf_counts = repos.group_by(&:name).transform_values(&:length)

        candidates = []
        repos.each do |repo|
          if prefix.include?("/")
            candidates << repo.org_repo
            relative = relative_path_string(repo)
            candidates << relative unless relative == repo.org_repo
          elsif leaf_counts.fetch(repo.name) == 1
            candidates << repo.name
          else
            candidates << repo.org_repo
          end
        end

        filter_completions(candidates.uniq, prefix).sort
      end

      private

      # @param query [String]
      # @return [Array<Hash>] entries with :repo and :score, best first
      def rank(query)
        query = query.to_s
        raise RepoNotFoundError, "dev: missing repo query" if query.empty?

        segments = query.split("/")
        @index.all.filter_map do |repo|
          score = score_repo(repo, query, segments)
          next unless score

          { repo: repo, score: score }
        end.sort_by { |entry| [-entry.fetch(:score), entry.fetch(:repo).path.to_s] }
      end

      # @param repo [Dev::Cd::Repo]
      # @param query [String]
      # @param segments [Array<String>]
      # @return [Integer, nil]
      def score_repo(repo, query, segments)
        if segments.length >= 2
          score_multi_segment(repo, query, segments)
        else
          segment_score(segments.first, repo.name)
        end
      end

      # Match `org/repo` (last two segments) and optionally a longer relative
      # path suffix under the search root (segment-fuzzy on each part).
      #
      # @param repo [Dev::Cd::Repo]
      # @param _query [String]
      # @param segments [Array<String>]
      # @return [Integer, nil]
      def score_multi_segment(repo, _query, segments)
        org_s = segment_score(segments[-2], repo.org)
        name_s = segment_score(segments[-1], repo.name)
        pair_score = combine_scores(org_s, name_s)

        relative_segments = relative_path_string(repo).split("/")
        path_score = score_segment_suffix(segments, relative_segments)

        [pair_score, path_score].compact.max
      end

      # @param left [Integer, nil]
      # @param right [Integer, nil]
      # @return [Integer, nil]
      def combine_scores(left, right)
        return nil if left.nil? || right.nil?

        # Weight so (exact, exact) > any mixed pair; stable across org/repo.
        (left * (SCORE_EXACT + 1)) + right
      end

      # Fuzzy-match query segments against the trailing path segments.
      #
      # @param query_segments [Array<String>]
      # @param path_segments [Array<String>]
      # @return [Integer, nil]
      def score_segment_suffix(query_segments, path_segments)
        return nil if query_segments.length > path_segments.length

        trailing = path_segments.last(query_segments.length)
        scores = query_segments.zip(trailing).map { |q, p| segment_score(q, p) }
        return nil if scores.any?(&:nil?)

        scores.reduce(0) { |acc, score| (acc * (SCORE_EXACT + 1)) + score }
      end

      # @param query [String]
      # @param candidate [String]
      # @return [Integer, nil]
      def segment_score(query, candidate)
        q = query.to_s.downcase
        c = candidate.to_s.downcase
        return nil if q.empty? || c.empty?
        return SCORE_EXACT if c == q
        return SCORE_PREFIX if c.start_with?(q)
        return SCORE_SUBSTRING if c.include?(q)

        nil
      end

      # @param repo [Dev::Cd::Repo]
      # @return [String]
      def relative_path_string(repo)
        repo.path.relative_path_from(@index.root).each_filename.to_a.join("/")
      end

      # @param candidates [Array<String>]
      # @param prefix [String]
      # @return [Array<String>]
      def filter_completions(candidates, prefix)
        return candidates if prefix.empty?

        p = prefix.downcase
        candidates.select { |c| c.downcase.start_with?(p) }
      end
    end
  end
end

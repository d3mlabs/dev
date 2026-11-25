# typed: strict
# frozen_string_literal: true

require_relative "series"

module Dev
  module Lifecycle
    # A channel's **head**: what a follower installs when it asks for
    # nothing in particular. One noun, one rule across channels — `release`
    # never moves a head, `deploy` moves exactly one — and two mechanisms a
    # publisher declares (HeadStrategy). This module holds the half of the
    # mechanism that is dev's: the rule a derived channel's head is
    # computed by. A pointed channel's head is read from its pointer by its
    # publisher, and dev computes nothing.
    #
    # A lock and a follower read the same head. A series-shaped
    # requirement (`~> 1`) on a pointed channel resolves to what the
    # series' pointer names (Deps::Resolver, through the universe's
    # Deps::SeriesHead facts), so after a rollback the lock and the `@v1`
    # follower both sit below the greatest tag; on a derived channel the
    # head and the greatest satisfying version are one rule. Still,
    # nothing here reads a Requirement or a VersionScheme — the head's
    # vocabulary is a series (`v1`) and the store's own version words, and
    # which requirements reach a head is the resolver's to say.
    module Head
      # Nothing in the store is a non-prerelease version (of the series):
      # the channel has no head for a follower to install.
      class NoHeadError < RuntimeError; end

      class << self
        extend T::Sig

        # The derived head: the greatest non-prerelease version among the
        # store's, within +series+ when one is given. The words are the
        # store's own spelling and the answer is one of them, so a caller
        # can look the version up where it came from. A word that is not a
        # version (`latest`, `toolchain-2` among bare tags) is not one of
        # the store's versions and is not a candidate.
        #
        # @param versions [Array<String>] the store's version words, in any order
        # @param series [Series, nil] the major to stay within; nil for the newest of all
        # @return [String] the head's version, as the store spells it
        # @raise [NoHeadError]
        sig { params(versions: T::Array[String], series: T.nilable(Series)).returns(String) }
        def derive(versions, series: nil)
          candidates = versions.select { |word| Series.version?(word) }.to_h { |word| [word, Gem::Version.new(word)] }
          released = candidates.reject { |_word, version| version.prerelease? }
          in_series = series.nil? ? released : released.select { |word, _version| series.includes?(word) }
          head = in_series.keys.max_by { |word| in_series.fetch(word) }
          raise NoHeadError, no_head_message(versions, series) if head.nil?

          head
        end

        private

        # @param versions [Array<String>] the store's version words
        # @param series [Series, nil]
        # @return [String]
        sig { params(versions: T::Array[String], series: T.nilable(Series)).returns(String) }
        def no_head_message(versions, series)
          where = series.nil? ? "" : " on #{series}"
          store = versions.empty? ? "the store has no versions" : "none of the store's versions is a release#{" of that series" unless series.nil?} (#{versions.join(", ")})"
          "no head#{where}: #{store}"
        end
      end
    end
  end
end

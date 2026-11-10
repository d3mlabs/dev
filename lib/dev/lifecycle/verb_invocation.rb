# typed: strict
# frozen_string_literal: true

require_relative "artifact_fetch"

module Dev
  module Lifecycle
    # A lifecycle verb as a remote host is told to run it (dev#192, K10):
    # the words after `dev` — the verb and its arguments, the build fully
    # qualified so the host never falls back to a default of its own —
    # and what the dispatch brings back afterwards (`--fetch`). What the
    # verb's `before` hands its dispatch beside the env: Native ignores
    # it; Remote runs it where the build's environment is and returns
    # Done.
    #
    # The words are what the generic workflow's `verbs` input carries and
    # what `docker exec dev …` will take (dev#421), so they are the
    # verb's own spelling with the dispatch flags consumed — a `--runner`
    # that crossed would make the host dispatch again — and no word may
    # carry the input's delimiter or whitespace: the job word-splits each
    # entry back into an argv.
    class VerbInvocation
      extend T::Sig

      # A word the `verbs` input cannot carry whole.
      class UnspeakableWordError < ArgumentError; end

      # No verb at all.
      class EmptyInvocationError < ArgumentError; end

      # What the workflow splits the input on, and what shells split a word on.
      FORBIDDEN = /[,\s]/

      # @return [Array<String>] the verb and its arguments, as typed after `dev`
      sig { returns(T::Array[String]) }
      attr_reader :words

      # @return [ArtifactFetch, nil] what to bring back; nil for nothing
      sig { returns(T.nilable(ArtifactFetch)) }
      attr_reader :fetch

      # @param words [Array<String>]
      # @param fetch [ArtifactFetch, nil]
      # @raise [EmptyInvocationError]
      # @raise [UnspeakableWordError]
      sig { params(words: T::Array[String], fetch: T.nilable(ArtifactFetch)).void }
      def initialize(words:, fetch: nil)
        raise EmptyInvocationError, "a verb invocation needs at least the verb" if words.empty?

        unspeakable = words.find { |word| word.empty? || FORBIDDEN.match?(word) }
        if unspeakable
          raise UnspeakableWordError,
            "#{unspeakable.inspect} cannot cross to a remote host as one word (no commas, no whitespace, not empty)"
        end

        @words = T.let(words.dup.freeze, T::Array[String])
        @fetch = fetch
        freeze
      end

      # @return [String] the verb's name
      sig { returns(String) }
      def verb
        T.must(@words.first)
      end

      # @return [String] the words as the `verbs` input spells one entry
      sig { returns(String) }
      def to_s
        @words.join(" ")
      end

      sig { params(other: Object).returns(T::Boolean) }
      def ==(other)
        other.is_a?(VerbInvocation) && words == other.words && fetch == other.fetch
      end

      sig { params(other: Object).returns(T::Boolean) }
      def eql?(other)
        self == other
      end

      sig { returns(Integer) }
      def hash
        [VerbInvocation, @words, @fetch].hash
      end
    end
  end
end

# typed: strict
# frozen_string_literal: true

require_relative "artifact_fetch"
require_relative "../value_equality"

module Dev
  module Lifecycle
    # A lifecycle verb as a remote host is told to run it: the words after
    # `dev`, with the build fully qualified so the host never falls back to
    # a default of its own, and what the dispatch brings back afterwards
    # (`--fetch`). Native dispatch ignores it; Remote runs it where the
    # build's environment is.
    #
    # The words are what the generic workflow's `verbs` input carries and
    # what `docker exec dev …` takes, with the dispatch flags consumed so
    # the host never dispatches again. No word may carry the input's
    # delimiter or whitespace: the job word-splits each entry back into an
    # argv.
    class VerbInvocation
      extend T::Sig
      include Dev::ValueEquality::Derived

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

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [@words, @fetch]
      end
    end
  end
end

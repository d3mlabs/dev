# typed: strict
# frozen_string_literal: true

module Dev
  module Cli
    # A command's argv after parsing against its flag vocabulary
    # (FlagVocabulary#parse): the switches present, each value flag's
    # values in argv order, the positionals with the `--` terminator
    # consumed — and the words as typed, for the shapes that forward their
    # argv to another process or command. Immutable; equal by value.
    class ParsedArgs
      extend T::Sig

      sig { returns(T::Array[String]) }
      attr_reader :words

      sig { returns(T::Array[String]) }
      attr_reader :positionals

      # @param words [Array<String>] the argv as typed, after the command path
      # @param positionals [Array<String>] the non-flag tokens
      # @param switches [Array<String>] the valueless flags present, by name
      # @param values [Hash{String => Array<String>}] each value flag's
      #   values, in argv order
      sig do
        params(
          words: T::Array[String],
          positionals: T::Array[String],
          switches: T::Array[String],
          values: T::Hash[String, T::Array[String]],
        ).void
      end
      def initialize(words: [], positionals: [], switches: [], values: {})
        @words = T.let(words.freeze, T::Array[String])
        @positionals = T.let(positionals.freeze, T::Array[String])
        @switches = T.let(switches.freeze, T::Array[String])
        @values = T.let(values.freeze, T::Hash[String, T::Array[String]])
      end

      # Whether the flag was given, as a switch or with a value.
      #
      # @param name [String] the flag as declared, e.g. "--org"
      # @return [Boolean]
      sig { params(name: String).returns(T::Boolean) }
      def flag?(name)
        @switches.include?(name) || @values.key?(name)
      end

      # The flag's value — the last one when repeated, as getopt does — or
      # nil when absent.
      #
      # @param name [String] the flag as declared, e.g. "--keep"
      # @return [String, nil]
      sig { params(name: String).returns(T.nilable(String)) }
      def value(name)
        @values[name]&.last
      end

      # Every value of the flag, in argv order; empty when absent.
      #
      # @param name [String] the flag as declared, e.g. "--group"
      # @return [Array<String>]
      sig { params(name: String).returns(T::Array[String]) }
      def values(name)
        @values.fetch(name, [])
      end

      sig { params(other: Object).returns(T::Boolean) }
      def ==(other)
        return false unless other.is_a?(ParsedArgs)

        state == other.state
      end
      alias eql? ==

      sig { returns(Integer) }
      def hash = state.hash

      protected

      # @return [Array] the value this object is equal by
      sig { returns([T::Array[String], T::Array[String], T::Array[String], T::Hash[String, T::Array[String]]]) }
      def state = [@words, @positionals, @switches, @values]
    end
  end
end

# typed: strict
# frozen_string_literal: true

module Dev
  module Cli
    # One positional argument a command declares (Command#positionals): the
    # word its usage spells as a placeholder — `declaration` renders as
    # `<declaration>` — what it stands for, whether the operator may leave it
    # out, and whether it may be given more than once. The vocabulary a
    # command's help renders from, and nothing more: parsing knows nothing
    # of it — a builtin reads its positionals in order
    # (ParsedArgs#positionals) and refuses a shape it does not take itself.
    class Positional
      extend T::Sig

      # A declared name that is not a bare word: a programming error in the
      # declaring command, surfaced at load (the brackets and markers are
      # the rendering's to add, never the name's).
      class MalformedNameError < ArgumentError; end

      NAME_PATTERN = /\A[a-z][a-z0-9-]*\z/

      # What the usage line appends to a placeholder that may repeat.
      REPEAT_MARK = "…"

      sig { returns(String) }
      attr_reader :name

      # The one line the command's usage prints beside the placeholder.
      sig { returns(String) }
      attr_reader :desc

      # @param name [String] the placeholder's word, e.g. "declaration"
      # @param desc [String] what the argument is, for the Arguments block
      # @param optional [Boolean] whether the operator may leave it out
      # @param repeated [Boolean] whether it may be given more than once
      # @raise [MalformedNameError] for a name that is not a bare word
      sig { params(name: String, desc: String, optional: T::Boolean, repeated: T::Boolean).void }
      def initialize(name, desc:, optional: false, repeated: false)
        raise MalformedNameError, "#{name.inspect} is not a positional name" unless name.match?(NAME_PATTERN)

        @name = name
        @desc = desc
        @optional = optional
        @repeated = repeated
      end

      # @return [Boolean]
      sig { returns(T::Boolean) }
      def optional?
        @optional
      end

      # @return [Boolean]
      sig { returns(T::Boolean) }
      def repeated?
        @repeated
      end

      # The placeholder as the Arguments block labels it: `<name>`.
      #
      # @return [String]
      sig { returns(String) }
      def placeholder
        "<#{@name}>"
      end

      # The placeholder as the usage line spells it, markers included:
      # `<name>`, `[<name>]`, `<name>…` or `[<name>…]`.
      #
      # @return [String]
      sig { returns(String) }
      def usage
        marked = @repeated ? "#{placeholder}#{REPEAT_MARK}" : placeholder
        @optional ? "[#{marked}]" : marked
      end
    end
  end
end

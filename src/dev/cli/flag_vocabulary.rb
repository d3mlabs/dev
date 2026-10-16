# typed: strict
# frozen_string_literal: true

require_relative "../command"

module Dev
  module Cli
    # The one rule for `-`-prefixed arguments at a dev-defined node (#217),
    # the cobra/gh convention: `-h` / `--help` anywhere among a node's
    # arguments asks for that node's usage; any other flag not in the node's
    # declared vocabulary (Command#flags) is a usage error; a literal `--`
    # ends option parsing, so everything after it is positional data —
    # neither help nor a violation. Opaque nodes (Command#opaque_args?: a
    # project `run:`, `complete`) are exempt: their argv is someone else's
    # and is forwarded untouched.
    #
    # Stateless. Admission happens before a command sees its args, so a
    # builtin hand-parses only the flags it declared: nothing else reaches
    # it.
    class FlagVocabulary
      extend T::Sig

      # Every dev-defined node answers to these.
      HELP_FLAGS = T.let(["-h", "--help"].freeze, T::Array[String])
      # getopt's end-of-options marker.
      TERMINATOR = "--"

      # A `-`-prefixed argument outside the node's vocabulary. Carries the
      # node so the CLI boundary can print its usage beside the message.
      class UnknownFlagError < StandardError
        extend T::Sig

        sig { returns(String) }
        attr_reader :flag

        sig { returns(T::Array[String]) }
        attr_reader :path

        sig { returns(Command) }
        attr_reader :command

        # @param flag [String] the offending token, as typed
        # @param path [Array<String>] the node's path from the root
        # @param command [Command] the node
        sig { params(flag: String, path: T::Array[String], command: Command).void }
        def initialize(flag:, path:, command:)
          @flag = flag
          @path = path
          @command = command
          super("unknown flag '#{flag}' for '#{["dev", *path].join(" ")}'")
        end
      end

      # Whether a token is an option name: `-`-prefixed, but neither the lone
      # `-` (stdin, by convention) nor the `--` terminator.
      #
      # @param token [String]
      # @return [Boolean]
      sig { params(token: String).returns(T::Boolean) }
      def flag?(token)
        token.start_with?("-") && token.length > 1 && token != TERMINATOR
      end

      # Whether the args ask for help: a help flag anywhere before the
      # terminator. Callers decide what the node is first — an opaque node's
      # `--help` is data (Command#opaque_args?).
      #
      # @param args [Array<String>] a node's args (argv after its path)
      # @return [Boolean]
      sig { params(args: T::Array[String]).returns(T::Boolean) }
      def help_requested?(args)
        options(args).any? { |token| HELP_FLAGS.include?(token) }
      end

      # The args the node receives: verbatim for an opaque node; otherwise
      # checked against its vocabulary and with the terminator consumed, so
      # a builtin sees `--help` after `--` as the positional it is.
      #
      # @param command [Command] the resolved node
      # @param path [Array<String>] the path that reached it
      # @param args [Array<String>] the tokens left over for it
      # @return [Array<String>]
      # @raise [UnknownFlagError] for a flag outside the node's vocabulary
      sig { params(command: Command, path: T::Array[String], args: T::Array[String]).returns(T::Array[String]) }
      def admit(command, path:, args:)
        return args if command.opaque_args?

        vocabulary = command.flags.map(&:name) + HELP_FLAGS
        unknown = options(args).find { |token| flag?(token) && !vocabulary.include?(name_of(token)) }
        raise UnknownFlagError.new(flag: unknown, path:, command:) if unknown

        without_terminator(args)
      end

      private

      # The tokens option parsing applies to: everything before the first
      # terminator (all of them when there is none).
      #
      # @param args [Array<String>]
      # @return [Array<String>]
      sig { params(args: T::Array[String]).returns(T::Array[String]) }
      def options(args)
        index = args.index(TERMINATOR)
        index ? T.must(args[0...index]) : args
      end

      # The flag's name: `--keep=3` is `--keep`.
      #
      # @param token [String]
      # @return [String]
      sig { params(token: String).returns(String) }
      def name_of(token)
        token.split("=", 2).fetch(0)
      end

      # The args without their first terminator (the only one getopt reads).
      #
      # @param args [Array<String>]
      # @return [Array<String>]
      sig { params(args: T::Array[String]).returns(T::Array[String]) }
      def without_terminator(args)
        index = args.index(TERMINATOR)
        return args if index.nil?

        [*T.must(args[0...index]), *T.must(args[(index + 1)..])]
      end
    end
  end
end

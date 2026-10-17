# typed: strict
# frozen_string_literal: true

require_relative "../command"
require_relative "flag"
require_relative "parsed_args"

module Dev
  module Cli
    # The one rule for `-`-prefixed arguments at a dev-defined node (#217),
    # the cobra/gh convention: `-h` / `--help` anywhere among a node's
    # arguments asks for that node's usage; any other flag not in the node's
    # declared vocabulary (Command#flags) is a usage error, as is a value
    # flag with no value or a switch given one; a literal `--` ends option
    # parsing, so everything after it is positional data — neither help nor
    # a violation. A value flag consumes the next token whatever its shape
    # (`--labels -x`). Opaque nodes (Command#opaque_args?: a project `run:`,
    # `complete`) are exempt: their argv is someone else's and is forwarded
    # untouched.
    #
    # Stateless. Parsing happens before a command sees its args, so a
    # builtin reads only the flags it declared (ParsedArgs): nothing else
    # reaches it.
    class FlagVocabulary
      extend T::Sig

      # Every dev-defined node answers to these.
      HELP_FLAGS = T.let(["-h", "--help"].freeze, T::Array[String])
      # getopt's end-of-options marker.
      TERMINATOR = "--"

      # A malformed command line at a node. Carries the node so the CLI
      # boundary can print its usage beside the message.
      class UsageError < StandardError
        extend T::Sig

        sig { returns(String) }
        attr_reader :flag

        sig { returns(T::Array[String]) }
        attr_reader :path

        sig { returns(Command) }
        attr_reader :command

        # @param flag [String] the flag at fault, as typed
        # @param path [Array<String>] the node's path from the root
        # @param command [Command] the node
        # @param message [String] what is wrong with the flag
        sig { params(flag: String, path: T::Array[String], command: Command, message: String).void }
        def initialize(flag:, path:, command:, message:)
          @flag = flag
          @path = path
          @command = command
          super("#{message} for '#{["dev", *path].join(" ")}'")
        end
      end

      # A `-`-prefixed argument outside the node's vocabulary.
      class UnknownFlagError < UsageError
        sig { params(flag: String, path: T::Array[String], command: Command).void }
        def initialize(flag:, path:, command:)
          super(flag:, path:, command:, message: "unknown flag '#{flag}'")
        end
      end

      # A value flag as the last token, with nothing to take.
      class MissingFlagValueError < UsageError
        sig { params(flag: String, path: T::Array[String], command: Command).void }
        def initialize(flag:, path:, command:)
          super(flag:, path:, command:, message: "flag '#{flag}' needs a value")
        end
      end

      # A switch given an inline value (`--org=yes`).
      class UnexpectedFlagValueError < UsageError
        sig { params(flag: String, path: T::Array[String], command: Command).void }
        def initialize(flag:, path:, command:)
          super(flag:, path:, command:, message: "flag '#{flag}' takes no value")
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

      # The node's args, parsed against its vocabulary: verbatim for an
      # opaque node (the words are the positionals too); otherwise each flag
      # read by its declared arity and the terminator consumed, so a builtin
      # sees `--help` after `--` as the positional it is.
      #
      # @param command [Command] the resolved node
      # @param path [Array<String>] the path that reached it
      # @param args [Array<String>] the tokens left over for it
      # @return [ParsedArgs]
      # @raise [UnknownFlagError] for a flag outside the node's vocabulary
      # @raise [MissingFlagValueError] for a value flag with nothing after it
      # @raise [UnexpectedFlagValueError] for a switch given an inline value
      sig { params(command: Command, path: T::Array[String], args: T::Array[String]).returns(ParsedArgs) }
      def parse(command, path:, args:)
        return ParsedArgs.new(words: args, positionals: args) if command.opaque_args?

        declared = command.flags.to_h { |flag| [flag.name, flag] }
        positionals = T.let([], T::Array[String])
        switches = T.let([], T::Array[String])
        values = T.let({}, T::Hash[String, T::Array[String]])
        tokens = args.dup
        while (token = tokens.shift)
          if token == TERMINATOR
            positionals.concat(tokens)
            break
          end
          unless flag?(token)
            positionals << token
            next
          end

          name, inline_value = token.split("=", 2)
          name = T.must(name)
          if HELP_FLAGS.include?(name)
            switches << name
            next
          end

          flag = declared[name]
          raise UnknownFlagError.new(flag: token, path:, command:) if flag.nil?

          if flag.takes_value?
            value = inline_value || tokens.shift
            raise MissingFlagValueError.new(flag: name, path:, command:) if value.nil?

            (values[name] ||= []) << value
          else
            raise UnexpectedFlagValueError.new(flag: name, path:, command:) unless inline_value.nil?

            switches << name
          end
        end

        ParsedArgs.new(words: args, positionals:, switches:, values:)
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
    end
  end
end

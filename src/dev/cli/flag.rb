# typed: strict
# frozen_string_literal: true

module Dev
  module Cli
    # One `-`-prefixed argument a command declares (Command#flags): its name
    # as typed, dashes included, and whether it consumes a value — `--keep
    # 3` / `--keep=3` — or stands alone (`--org`). The arity is what lets a
    # value be anything, `-x` included, without being mistaken for a flag.
    class Flag
      extend T::Sig

      # A declared name that is not `-`/`--` plus a word: a programming
      # error in the declaring command, surfaced at load.
      class MalformedNameError < ArgumentError; end

      NAME_PATTERN = /\A--?[A-Za-z][A-Za-z0-9-]*\z/

      sig { returns(String) }
      attr_reader :name

      # The one line the command's usage prints beside the flag; empty
      # lists the flag by name alone.
      sig { returns(String) }
      attr_reader :desc

      # @param name [String] the flag as typed, e.g. "--keep"
      # @param takes_value [Boolean] whether the flag consumes a value
      # @param desc [String] what the flag does, for the usage listing
      # @raise [MalformedNameError] for a name that is not a flag
      sig { params(name: String, takes_value: T::Boolean, desc: String).void }
      def initialize(name, takes_value: false, desc: "")
        raise MalformedNameError, "#{name.inspect} is not a flag name" unless name.match?(NAME_PATTERN)

        @name = name
        @takes_value = takes_value
        @desc = desc
      end

      # @return [Boolean]
      sig { returns(T::Boolean) }
      def takes_value? = @takes_value
    end
  end
end

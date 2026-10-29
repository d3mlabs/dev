# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module Dev
  module Deps
    # Which declarations a re-lock floats — bundler's unlock set. A bare
    # `dev deps update` floats none: every pin the lock on disk can keep, it
    # keeps (`bundle install`). `dev deps update <name>…` floats the named
    # declarations and what they pull in through integration needs
    # (`bundle update <gem>`). `--all` floats everything: the intentional
    # "take what the channels have today" re-lock. Immutable; equal by
    # value.
    class UnlockSet
      extend T::Sig

      # @return [Array<String>] the declaration names floated by name;
      #   empty when none or all
      sig { returns(T::Array[String]) }
      attr_reader :names

      # @param names [Array<String>] declaration names to float
      # @param all [Boolean] float every declaration (names are then moot)
      sig { params(names: T::Array[String], all: T::Boolean).void }
      def initialize(names: [], all: false)
        @names = T.let(names.uniq.freeze, T::Array[String])
        @all = all
        freeze
      end

      class << self
        extend T::Sig

        # @return [UnlockSet] the conservative re-lock: nothing floats
        sig { returns(UnlockSet) }
        def none = new

        # @return [UnlockSet] the full re-lock: everything floats
        sig { returns(UnlockSet) }
        def all = new(all: true)
      end

      # @return [Boolean] whether every declaration floats
      sig { returns(T::Boolean) }
      def all? = @all

      # @return [Boolean] whether this is a subset re-lock — some
      #   declarations float by name and every other pin is the lock's
      sig { returns(T::Boolean) }
      def subset? = !@all && @names.any?

      # @param name [String] a declaration (or pin) name
      # @return [Boolean] whether the author asked for this name to float
      sig { params(name: String).returns(T::Boolean) }
      def floats?(name)
        @all || @names.include?(name)
      end

      sig { params(other: Object).returns(T::Boolean) }
      def ==(other)
        return false unless other.is_a?(UnlockSet)

        [all?, names] == [other.all?, other.names]
      end
      alias_method :eql?, :==

      sig { returns(Integer) }
      def hash
        [self.class, all?, names].hash
      end
    end
  end
end

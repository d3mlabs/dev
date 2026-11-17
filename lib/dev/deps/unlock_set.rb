# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "../value_equality"

module Dev
  module Deps
    # Which declarations a re-lock floats — bundler's unlock set. A bare
    # `dev deps update` floats every declaration: each pin is re-resolved
    # to the newest version its declaration admits (`bundle lock --update`).
    # `dev deps update <name>…` floats the named declarations and what they
    # pull in through integration needs, and every other pin the lock can
    # keep, it keeps (`bundle update <gem>`). Immutable; equal by value.
    class UnlockSet
      extend T::Sig
      include Dev::ValueEquality::Derived

      # @return [Array<String>] the declaration names floated by name;
      #   empty when every declaration floats
      sig { returns(T::Array[String]) }
      attr_reader :names

      # @param names [Array<String>] declaration names to float; none
      #   floats every declaration
      sig { params(names: T::Array[String]).void }
      def initialize(names: [])
        @names = T.let(names.uniq.freeze, T::Array[String])
        freeze
      end

      class << self
        extend T::Sig

        # @return [UnlockSet] the bare re-lock: everything floats
        sig { returns(UnlockSet) }
        def all
          new
        end
      end

      # @return [Boolean] whether every declaration floats
      sig { returns(T::Boolean) }
      def all?
        @names.empty?
      end

      # @return [Boolean] whether this is a subset re-lock — some
      #   declarations float by name and every other pin is kept where
      #   the lock can keep it
      sig { returns(T::Boolean) }
      def subset?
        @names.any?
      end

      # @param name [String] a declaration (or pin) name
      # @return [Boolean] whether the author asked for this name to float
      sig { params(name: String).returns(T::Boolean) }
      def floats?(name)
        all? || @names.include?(name)
      end

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [names]
      end
    end
  end
end

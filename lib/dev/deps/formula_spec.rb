# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "../value_equality"
require_relative "requirement"

module Dev
  module Deps
    # A Homebrew formula spec as a manifest writes it: `name`, or
    # `name@suffix` naming one member of a versioned family (`llvm@18`,
    # `python@3.12`, `openssl@1.1`). The suffix is brew's spelling of "the
    # 18 line", which in dev's requirement language is `~> 18.0` — the
    # family member's real versions are what a requirement is evaluated
    # over, never the suffix itself.
    class FormulaSpec
      extend T::Sig
      include Dev::ValueEquality::Derived

      # The spec is not `name` or `name@<dotted digits>`.
      class InvalidSpecError < StandardError; end

      # A versioned family's suffix is dotted digits: that is the only shape
      # a requirement can be read off.
      PATTERN = /\A([^@\s]+)(?:@(\d+(?:\.\d+)*))?\z/

      # @return [String] the bare formula name
      sig { returns(String) }
      attr_reader :name

      # @return [String, nil] the family suffix, when the spec named a member
      sig { returns(T.nilable(String)) }
      attr_reader :suffix

      # @param name [String]
      # @param suffix [String, nil]
      sig { params(name: String, suffix: T.nilable(String)).void }
      def initialize(name:, suffix: nil)
        @name = name
        @suffix = suffix
        freeze
      end

      # @return [Boolean] whether the spec names a versioned family member
      sig { returns(T::Boolean) }
      def versioned?
        !suffix.nil?
      end

      # The requirement a family suffix stands for: `~> <suffix>.0`, every
      # version of that line (`@18` → `~> 18.0`, `@3.12` → `~> 3.12.0`).
      #
      # @return [Requirement] Any for a bare spec
      sig { returns(Requirement) }
      def requirement
        return Requirement::Any.new unless suffix

        Requirement::Pessimistic.new(version: "#{suffix}.0")
      end

      # @return [String] `name` or `name@suffix`
      sig { returns(String) }
      def to_s
        suffix ? "#{name}@#{suffix}" : name
      end

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [name, suffix]
      end

      class << self
        extend T::Sig

        # @param spec [String] `name` or `name@suffix`
        # @return [FormulaSpec]
        # @raise [InvalidSpecError] if the spec is empty or its suffix is not dotted digits
        sig { params(spec: String).returns(FormulaSpec) }
        def parse(spec)
          match = PATTERN.match(spec)
          unless match
            raise InvalidSpecError,
              "#{spec.inspect} is not a formula spec — `name` or `name@<version line>` (llvm@18, python@3.12)"
          end

          new(name: T.must(match[1]), suffix: match[2])
        end
      end
    end
  end
end

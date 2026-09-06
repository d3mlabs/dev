# typed: strict
# frozen_string_literal: true

require_relative "declaration"

module Dev
  module Deps
    # A PackageVersion's claim about its declared dependencies — a sum type,
    # because a bare array cannot say which regime the claim was made under:
    # [] would collapse "this version affirmatively requires nothing" into
    # "the ecosystem's own tool owns a closure dev never sees".
    #
    # Exactly two variants, sealed so consumers can case-and-T.absurd:
    #
    # - Resolved(declarations): the repository reports the version's declared
    #   deps as facts dev can walk. Resolved([]) is the affirmative empty
    #   claim — including self-contained ecosystems (steam, gh artifacts)
    #   where the repository guarantees it by construction.
    # - ToolOwned: the ecosystem's tool (bundler, pip, luarocks, brew) owns
    #   transitive resolution; dev sees only the top-level asks.
    #
    # The claim travels with the data: each Repository constructs the variant
    # its regime warrants — construction is the dispatch, so no resolver
    # guard, registry attribute, or repository enum exists.
    #
    # See the transitive-dependency regimes table in docs/deps-architecture.md.
    class Declarations
      extend T::Sig
      extend T::Helpers
      abstract!
      sealed!

      # The declared deps are facts dev can walk.
      class Resolved < Declarations
        extend T::Sig

        # @return [Array<Declaration>] the version's declared dependencies,
        #   normalized and integration-stamped by the reporting Repository
        sig { returns(T::Array[Declaration]) }
        attr_reader :declarations

        # @param declarations [Array<Declaration>] declared deps; [] is the
        #   affirmative "requires nothing"
        sig { params(declarations: T::Array[Declaration]).void }
        def initialize(declarations)
          @declarations = T.let(declarations.dup.freeze, T::Array[Declaration])
          freeze
        end

        # @param other [Object]
        # @return [Boolean] whether other makes the same claim
        sig { params(other: T.untyped).returns(T::Boolean) }
        def ==(other)
          return false unless other.is_a?(Resolved)

          declarations == other.declarations
        end
        alias_method :eql?, :==

        # @return [Integer] hash code
        sig { returns(Integer) }
        def hash
          [self.class, declarations].hash
        end
      end

      # The ecosystem's tool owns transitive resolution; dev cannot see the
      # closure and must not pretend to.
      class ToolOwned < Declarations
        extend T::Sig

        sig { void }
        def initialize
          freeze
        end

        # @param other [Object]
        # @return [Boolean] whether other is also a tool-owned claim
        sig { params(other: T.untyped).returns(T::Boolean) }
        def ==(other)
          other.is_a?(ToolOwned)
        end
        alias_method :eql?, :==

        # @return [Integer] hash code
        sig { returns(Integer) }
        def hash
          self.class.hash
        end
      end
    end
  end
end

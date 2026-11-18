# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "../value_equality"

module Dev
  module Deps
    # The one requirement language every declaration speaks: what a
    # dependencies.rb row asks of a package's versions, as a small AST —
    # `Any`, `Exact(v)`, `Pessimistic(v)`, `Bounds([op, v]…)` — parsed from
    # Gem::Requirement's syntax (`= 4.0.1`, `~> 18.0`, `>= 2, < 3`).
    #
    # The language is dev's; the meaning of a version string is each
    # channel's (VersionScheme): a scheme translates the requirement into
    # its tool's grammar (bundler) or evaluates it under its own ordering
    # (pip, brew, gh). What `~>` means is fixed here, once — `~> v` is
    # `>= v, < bump(v)` with rubygems' bump — so every channel reads it
    # alike, PEP 440's `~=` included.
    #
    # Sealed, so a consumer cases on the variants and T.absurd the rest.
    class Requirement
      extend T::Sig
      extend T::Helpers
      abstract!
      sealed!

      # The expression is not a rubygems requirement (an unknown operator,
      # a version that is not dotted alphanumerics).
      class ParseError < StandardError; end

      # The operators Gem::Requirement reads, besides `~>`.
      COMPARATORS = T.let(%w[= != > < >= <=].freeze, T::Array[String])
      PESSIMISTIC = "~>"
      EXACT = "="
      # One term: an optional rubygems operator, then a digit-led version
      # word, whitespace around either.
      TERM_PATTERN = /\A\s*(=|!=|>=|<=|>|<|~>)?\s*([0-9]\S*)\s*\z/

      # One comparator term: `>= 2`.
      class Bound
        extend T::Sig
        include Dev::ValueEquality::Derived

        # @return [String] one of COMPARATORS or PESSIMISTIC
        sig { returns(String) }
        attr_reader :operator

        # @return [String] the version as written
        sig { returns(String) }
        attr_reader :version

        # @param operator [String]
        # @param version [String]
        sig { params(operator: String, version: String).void }
        def initialize(operator:, version:)
          @operator = operator
          @version = version
          freeze
        end

        # @return [String] the term in rubygems syntax
        sig { returns(String) }
        def to_s
          "#{operator} #{version}"
        end

        # @return [Array] the members that constitute identity
        sig { override.returns(T::Array[T.anything]) }
        def equality_members
          [operator, version]
        end
      end

      # No ask: any version the channel publishes.
      class Any < Requirement
        extend T::Sig
        include Dev::ValueEquality::Derived

        sig { void }
        def initialize
          freeze
        end

        # @return [String] the empty expression
        sig { override.returns(String) }
        def to_s
          ""
        end

        # @return [Array<Bound>] no terms
        sig { override.returns(T::Array[Bound]) }
        def terms
          []
        end

        # @return [Array] the members that constitute identity
        sig { override.returns(T::Array[T.anything]) }
        def equality_members
          []
        end
      end

      # One version: `= 4.0.1`. Also what a channel's exact coordinate (a
      # gh `tag:`, a steam `buildid:`) is, however it is spelled — an Exact
      # built by a DSL keyword carries the coordinate verbatim, which is why
      # the version is a String and not a parsed one.
      class Exact < Requirement
        extend T::Sig
        include Dev::ValueEquality::Derived

        # @return [String] the one version asked for
        sig { returns(String) }
        attr_reader :version

        # @param version [String]
        sig { params(version: String).void }
        def initialize(version:)
          @version = version
          freeze
        end

        # @return [String] `= <version>`
        sig { override.returns(String) }
        def to_s
          "#{EXACT} #{version}"
        end

        # @return [Array<Bound>] the one `=` term
        sig { override.returns(T::Array[Bound]) }
        def terms
          [Bound.new(operator: EXACT, version: version)]
        end

        # @return [Array] the members that constitute identity
        sig { override.returns(T::Array[T.anything]) }
        def equality_members
          [version]
        end
      end

      # `~> v`: at least v, below the next release of v's second-to-last
      # segment (`~> 18.0` is `>= 18.0, < 19`; `~> 1.2.3` is `>= 1.2.3,
      # < 1.3`; `~> 18` is `>= 18, < 19`).
      class Pessimistic < Requirement
        extend T::Sig
        include Dev::ValueEquality::Derived

        # @return [String] the floor
        sig { returns(String) }
        attr_reader :version

        # @param version [String] a rubygems-shaped version — `~>` has no
        #   meaning over a coordinate rubygems cannot bump
        # @raise [ParseError] if the version is not rubygems-shaped
        sig { params(version: String).void }
        def initialize(version:)
          raise ParseError, "#{PESSIMISTIC} #{version.inspect}: not a version rubygems can bump" unless Gem::Version.correct?(version)

          @version = version
          freeze
        end

        # @return [String] `~> <version>`
        sig { override.returns(String) }
        def to_s
          "#{PESSIMISTIC} #{version}"
        end

        # @return [Array<Bound>] the one `~>` term
        sig { override.returns(T::Array[Bound]) }
        def terms
          [Bound.new(operator: PESSIMISTIC, version: version)]
        end

        # The two comparator terms the operator stands for, so a channel
        # evaluates `~>` with nothing but its own ordering.
        #
        # @return [Array<Bound>] `>= v`, `< bump(v)`
        sig { override.returns(T::Array[Bound]) }
        def bounds
          [
            Bound.new(operator: ">=", version: version),
            Bound.new(operator: "<", version: Gem::Version.new(version).bump.to_s),
          ]
        end

        # @return [Array] the members that constitute identity
        sig { override.returns(T::Array[T.anything]) }
        def equality_members
          [version]
        end
      end

      # A conjunction of terms: `>= 2, < 3`, `>= 1.0, != 1.2`. Also the home
      # of a `~>` or `=` that arrives beside other terms (`~> 1.0, >= 1.0.5`).
      class Bounds < Requirement
        extend T::Sig
        include Dev::ValueEquality::Derived

        # @return [Array<Bound>] the terms, every one of which must hold
        sig { override.returns(T::Array[Bound]) }
        attr_reader :terms

        # @param terms [Array<Bound>]
        sig { params(terms: T::Array[Bound]).void }
        def initialize(terms:)
          @terms = T.let(terms.dup.freeze, T::Array[Bound])
          freeze
        end

        # @return [String] the terms joined as rubygems writes them
        sig { override.returns(String) }
        def to_s
          terms.join(", ")
        end

        # @return [Array] the members that constitute identity
        sig { override.returns(T::Array[T.anything]) }
        def equality_members
          [terms]
        end
      end

      # @return [String] the requirement in rubygems syntax; parse(to_s) == self
      sig { abstract.returns(String) }
      def to_s; end

      # The requirement as the terms it was written in, `~>` included: what
      # a channel that translates (GemScheme#render) hands its tool.
      #
      # @return [Array<Bound>]
      sig { abstract.returns(T::Array[Bound]) }
      def terms; end

      # The requirement as comparator terms only (`=`, `!=`, `>`, `<`, `>=`,
      # `<=`), every `~>` expanded to its two comparators: what a channel
      # that evaluates reads under its own ordering.
      #
      # @return [Array<Bound>]
      sig { overridable.returns(T::Array[Bound]) }
      def bounds
        terms.flat_map do |term|
          term.operator == PESSIMISTIC ? Pessimistic.new(version: term.version).bounds : [term]
        end
      end

      # @return [Boolean] whether this is the empty ask
      sig { returns(T::Boolean) }
      def any?
        is_a?(Any)
      end

      class << self
        extend T::Sig

        # Parse a rubygems requirement expression into its canonical node:
        # nothing is Any, one `=` term is Exact, one `~>` term is
        # Pessimistic, anything else is Bounds in the terms' written order.
        #
        # @param expression [String, nil] e.g. "~> 18.0", ">= 2, < 3", "4.0.1"
        # @return [Requirement]
        # @raise [ParseError] if any term is not a rubygems requirement
        sig { params(expression: T.nilable(String)).returns(Requirement) }
        def parse(expression)
          terms = expression.to_s.split(",").map(&:strip).reject(&:empty?).map { |term| bound(term) }
          return Any.new if terms.empty?

          if terms.size == 1
            only = T.must(terms.first)
            return Exact.new(version: only.version) if only.operator == EXACT
            return Pessimistic.new(version: only.version) if only.operator == PESSIMISTIC
          end
          Bounds.new(terms: terms)
        end

        private

        # One term: rubygems' operator, then a version kept as written. The
        # version token is any digit-led word rather than Gem::Version's
        # grammar, because what a version is belongs to the channel (brew's
        # `3.11.4_1` is no rubygems version); only `~>` needs a version
        # rubygems can bump, and Pessimistic checks that.
        #
        # @param term [String] e.g. ">= 2", "4.0.1"
        # @return [Bound]
        # @raise [ParseError]
        sig { params(term: String).returns(Bound) }
        def bound(term)
          match = TERM_PATTERN.match(term)
          unless match
            raise ParseError,
              "#{term.inspect} is not a requirement — one of #{(COMPARATORS + [PESSIMISTIC]).join(" ")} " \
                "and a version (`~> 18.0`, `>= 2, < 3`, `4.0.1`)"
          end

          operator = match[1] || EXACT
          version = T.must(match[2])
          if operator == PESSIMISTIC && !Gem::Version.correct?(version)
            raise ParseError, "#{term.inspect}: #{PESSIMISTIC} needs a version rubygems can bump (`~> 18.0`)"
          end

          Bound.new(operator: operator, version: version)
        end
      end
    end
  end
end

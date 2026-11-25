# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "../value_equality"
require_relative "semver_version"

module Dev
  module Deps
    # The one requirement language every declaration speaks: what a
    # dependencies.rb row asks of a package's versions, as a small AST —
    # `Any`, `Exact(v)`, `Caret(v)`, `Tilde(v)`, `Bounds([op, v]…)` — parsed
    # from semver range syntax, node-semver's grammar: `1.2.3` (exact), `^1`,
    # `~1.2`, `>=1.0.0 <2.0.0` (comparators, whitespace or a comma between).
    #
    # The language is dev's; the meaning of a version string is each
    # channel's (VersionScheme): a scheme translates the requirement into
    # its tool's grammar (bundler) or evaluates it under its own ordering
    # (pip, brew, gh). What `^` and `~` mean is fixed here, once, over
    # semver.org's version shape: `^v` is `>= v` below the next release of
    # v's leftmost non-zero segment (`^1.2.3` < 2.0.0, `^0.2.3` < 0.3.0),
    # `~v` is `>= v` below the next release of its last written segment
    # (`~1.2.3` < 1.3.0, `~1` < 2.0.0) — so every channel reads them alike.
    #
    # bundler's `~>` is refused with the spelling it maps to: it is
    # rubygems' idiom, at home in the Gemfile GemScheme renders and nowhere
    # else in dependencies.rb.
    #
    # Sealed, so a consumer cases on the variants and T.absurd the rest.
    class Requirement
      extend T::Sig
      extend T::Helpers
      abstract!
      sealed!

      # The expression is not a semver range (an unknown operator, a word
      # that is not digit-led, a shorthand over a version that is not semver).
      class ParseError < StandardError; end

      # The expression uses bundler's `~>`; the message names the semver
      # spelling of the same range.
      class PessimisticOperatorError < ParseError; end

      # node-semver's comparators.
      COMPARATORS = T.let(%w[= > >= < <=].freeze, T::Array[String])
      CARET = "^"
      TILDE = "~"
      EXACT = "="
      # The range shorthands, each over a semver version.
      SHORTHANDS = T.let([CARET, TILDE].freeze, T::Array[String])
      OPERATORS = T.let((SHORTHANDS + COMPARATORS).freeze, T::Array[String])
      # bundler's operator, refused.
      PESSIMISTIC = "~>"
      # One term: an optional operator, then a digit-led version word.
      TERM_PATTERN = /\A(\^|~|>=|<=|>|<|=)?([0-9][^\s,]*)\z/
      # An operator spaced from its version (`>= 1.0`): node-semver reads
      # the two as one term, so the space is dropped before terms split.
      SPACED_OPERATOR = /(~>|\^|~|>=|<=|>|<|=)\s+/
      # What separates terms: whitespace, a comma, or both.
      SEPARATOR = /[\s,]+/

      # One term: `>=2`, `^1.2`.
      class Bound
        extend T::Sig
        include Dev::ValueEquality::Derived

        # @return [String] one of OPERATORS
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

        # @return [String] the term in semver range syntax
        sig { returns(String) }
        def to_s
          "#{operator}#{version}"
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

      # One version: `4.0.1` or `=4.0.1`. Also what a channel's exact
      # coordinate (a gh `tag:`, a steam `buildid:`) is, however it is
      # spelled — an Exact built by a DSL keyword carries the coordinate
      # verbatim, which is why the version is a String and not a parsed one.
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

        # @return [String] `=<version>`
        sig { override.returns(String) }
        def to_s
          "#{EXACT}#{version}"
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

      # A range shorthand over a semver version: `^v` or `~v`, each `>= v`
      # below an upper bound the operator derives from v's segments.
      class Shorthand < Requirement
        extend T::Sig
        extend T::Helpers
        include Dev::ValueEquality::Derived
        abstract!
        sealed!

        # @return [String] the floor, as written
        sig { returns(String) }
        attr_reader :version

        # @param version [String] a semver version, partial allowed —
        #   the shorthand has no meaning over a version it cannot bump
        # @raise [ParseError] if the version is not a semver version
        sig { params(version: String).void }
        def initialize(version:)
          @version = version
          @semver = T.let(semver(version), SemverVersion)
          freeze
        end

        # @return [String] `<operator><version>`
        sig { override.returns(String) }
        def to_s
          "#{operator}#{version}"
        end

        # @return [Array<Bound>] the one shorthand term
        sig { override.returns(T::Array[Bound]) }
        def terms
          [Bound.new(operator: operator, version: version)]
        end

        # The two comparator terms the shorthand stands for, so a channel
        # evaluates it with nothing but its own ordering: the floor with
        # every segment written and its prerelease kept, and the exclusive
        # upper bound.
        #
        # @return [Array<Bound>] `>= v`, `< upper(v)`
        sig { override.returns(T::Array[Bound]) }
        def bounds
          [
            Bound.new(operator: ">=", version: @semver.padded.to_s),
            Bound.new(operator: "<", version: upper(@semver).to_s),
          ]
        end

        # @return [Array] the members that constitute identity
        sig { override.returns(T::Array[T.anything]) }
        def equality_members
          [version]
        end

        # @return [String] CARET or TILDE
        sig { abstract.returns(String) }
        def operator; end

        protected

        # @param semver [SemverVersion] the floor
        # @return [SemverVersion] the exclusive upper bound
        sig { abstract.params(semver: SemverVersion).returns(SemverVersion) }
        def upper(semver); end

        private

        # @param version [String]
        # @return [SemverVersion]
        # @raise [ParseError] if the version is not a semver version
        sig { params(version: String).returns(SemverVersion) }
        def semver(version)
          SemverVersion.parse(version)
        rescue SemverVersion::InvalidVersionError
          raise ParseError,
            "#{operator}#{version}: #{operator} needs a semver version (MAJOR[.MINOR[.PATCH]][-prerelease]) — " \
              "over any other version shape write comparators (`>=#{version}`)"
        end
      end

      # `^v`: at least v, below the next release of v's leftmost non-zero
      # segment — the compatible range under semver's "0.x is unstable"
      # reading (`^1.2.3` is `>=1.2.3 <2.0.0`, `^0.2.3` is `>=0.2.3 <0.3.0`,
      # `^0.0.3` is `>=0.0.3 <0.0.4`, `^1` is `>=1.0.0 <2.0.0`).
      class Caret < Shorthand
        extend T::Sig

        # @return [String] CARET
        sig { override.returns(String) }
        def operator
          CARET
        end

        protected

        # The leftmost non-zero written segment bumps; all zeros, the last
        # written one does (`^0` < 1.0.0, `^0.0` < 0.1.0, `^0.0.0` < 0.0.1).
        #
        # @param semver [SemverVersion]
        # @return [SemverVersion]
        sig { override.params(semver: SemverVersion).returns(SemverVersion) }
        def upper(semver)
          segments = semver.segments
          semver.bump(segments.index(&:positive?) || segments.size - 1)
        end
      end

      # `~v`: at least v, below the next release of v's last written
      # segment's parent — the patch range (`~1.2.3` is `>=1.2.3 <1.3.0`,
      # `~1.2` is `>=1.2.0 <1.3.0`, `~1` is `>=1.0.0 <2.0.0`).
      class Tilde < Shorthand
        extend T::Sig

        # @return [String] TILDE
        sig { override.returns(String) }
        def operator
          TILDE
        end

        protected

        # The minor bumps when one was written, else the major.
        #
        # @param semver [SemverVersion]
        # @return [SemverVersion]
        sig { override.params(semver: SemverVersion).returns(SemverVersion) }
        def upper(semver)
          semver.bump([semver.segments.size - 1, 1].min)
        end
      end

      # A conjunction of terms: `>=2 <3`, `>=1.0 <1.2`. Also the home of a
      # shorthand or an `=` that arrives beside other terms (`^1 >=1.0.5`).
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

        # @return [String] the terms joined as node-semver writes them
        sig { override.returns(String) }
        def to_s
          terms.join(" ")
        end

        # @return [Array] the members that constitute identity
        sig { override.returns(T::Array[T.anything]) }
        def equality_members
          [terms]
        end
      end

      # @return [String] the requirement in semver range syntax; parse(to_s) == self
      sig { abstract.returns(String) }
      def to_s; end

      # The requirement as the terms it was written in, shorthands
      # included: what a message shows the author.
      #
      # @return [Array<Bound>]
      sig { abstract.returns(T::Array[Bound]) }
      def terms; end

      # The requirement as comparator terms only (`=`, `>`, `<`, `>=`,
      # `<=`), every shorthand expanded to its two comparators: what a
      # channel evaluates under its own ordering, and what GemScheme
      # renders for bundler.
      #
      # @return [Array<Bound>]
      sig { overridable.returns(T::Array[Bound]) }
      def bounds
        terms.flat_map do |term|
          case term.operator
          when CARET then Caret.new(version: term.version).bounds
          when TILDE then Tilde.new(version: term.version).bounds
          else [term]
          end
        end
      end

      # @return [Boolean] whether this is the empty ask
      sig { returns(T::Boolean) }
      def any?
        is_a?(Any)
      end

      class << self
        extend T::Sig

        # Parse a semver range expression into its canonical node: nothing
        # is Any, one `=` (or bare) term is Exact, one `^` term is Caret, one
        # `~` term is Tilde, anything else is Bounds in the terms' written
        # order.
        #
        # @param expression [String, nil] e.g. "^1", "~1.2", ">=1.0.0 <2.0.0", "4.0.1"
        # @return [Requirement]
        # @raise [PessimisticOperatorError] if a term uses bundler's `~>`
        # @raise [ParseError] if any term is not a semver range term
        sig { params(expression: T.nilable(String)).returns(Requirement) }
        def parse(expression)
          words = expression.to_s.gsub(SPACED_OPERATOR, '\1').strip.split(SEPARATOR).reject(&:empty?)
          terms = words.map { |word| term(word) }
          return Any.new if terms.empty?

          if terms.size == 1
            only = T.must(terms.first)
            case only.operator
            when EXACT then return Exact.new(version: only.version)
            when CARET then return Caret.new(version: only.version)
            when TILDE then return Tilde.new(version: only.version)
            end
          end
          Bounds.new(terms: terms)
        end

        private

        # One term: the operator, then a version kept as written. The
        # version word is any digit-led word rather than semver's grammar,
        # because what a version is belongs to the channel (brew's
        # `3.11.4_1` is no semver version, pip's `3.0rc1` neither); only
        # the shorthands need a version semver can bump, and Shorthand
        # checks that.
        #
        # @param word [String] e.g. ">=2", "^1.2", "4.0.1"
        # @return [Bound]
        # @raise [PessimisticOperatorError] if the word is a `~>` term
        # @raise [ParseError] if the word is no term
        sig { params(word: String).returns(Bound) }
        def term(word)
          raise PessimisticOperatorError, pessimistic_refusal(word.delete_prefix(PESSIMISTIC)) if word.start_with?(PESSIMISTIC)

          match = TERM_PATTERN.match(word)
          unless match
            raise ParseError,
              "#{word.inspect} is not a requirement — one of #{OPERATORS.join(" ")} and a version " \
                "(`^1`, `~1.2`, `>=1.0.0 <2.0.0`, `4.0.1`)"
          end

          version = T.must(match[2])
          # A shorthand's term comes from its node, so a version semver
          # cannot bump fails here, at parse, not at evaluation.
          case match[1]
          when CARET then Caret.new(version: version).terms.fetch(0)
          when TILDE then Tilde.new(version: version).terms.fetch(0)
          else Bound.new(operator: match[1] || EXACT, version: version)
          end
        end

        # Why `~> v` is refused, with the semver spelling of the same
        # range when it has one: `~> 1` and `~> 1.2` are carets (the major
        # bumps), `~> 1.2.3` is a tilde (the minor bumps), and anything
        # else is the comparator pair rubygems' bump gives.
        #
        # @param version [String] what followed `~>`
        # @return [String]
        sig { params(version: String).returns(String) }
        def pessimistic_refusal(version)
          replacement = pessimistic_replacement(version)
          spelled = replacement ? "#{PESSIMISTIC} #{version} → #{replacement}" : "#{PESSIMISTIC} #{version.inspect} has no semver spelling"
          "#{spelled}: #{PESSIMISTIC} is bundler's operator; dependencies.rb ranges are semver's " \
            "(#{OPERATORS.join(" ")}), and bundler's grammar stays in the Gemfile dev renders"
        end

        # @param version [String] what followed `~>`
        # @return [String, nil] the semver range equal to `~> version`, nil
        #   when rubygems cannot bump the version either
        sig { params(version: String).returns(T.nilable(String)) }
        def pessimistic_replacement(version)
          return nil unless Gem::Version.correct?(version)

          segments = version.split(".")
          if segments.all? { |segment| segment.match?(/\A\d+\z/) }
            return "#{CARET}#{version}" if segments.size == 1 || (segments.size == 2 && segments.first != "0")
            return "#{TILDE}#{version}" if segments.size == 3
          end
          ">=#{version} <#{Gem::Version.new(version).bump}"
        end
      end
    end
  end
end

# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "version_scheme"

module Dev
  module Deps
    # LuaRocks constraint semantics (:luarocks): dotted numeric versions with a
    # dash-separated rockspec revision ("3.4-1").
    #
    # NOT semver: the "-1" is a packaging revision that releases *above* its
    # unrevised version (3.4-1 > 3.4), where semver would read it as a
    # prerelease below it. That grammar difference is why luarocks gets its own
    # scheme instead of riding SemverScheme.
    #
    # Supported constraint syntax, per rockspec dependency grammar: comparators
    # (">=", ">", "<=", "<", "==", "="), pessimistic "~>" (rubygems-style), bare
    # exact versions, and comma-separated conjunction.
    class RockScheme < VersionScheme
      extend T::Sig

      # The constraint expression is not parseable rockspec constraint syntax.
      class InvalidConstraintError < StandardError; end
      # The version string is not a luarocks version.
      class InvalidVersionError < StandardError; end

      # The constraint key carrying the expression (the luarocks DSL's
      # positional constraint lands under "constraint").
      CONSTRAINT_KEY = "constraint"

      # Dotted numeric segments with an optional numeric -revision.
      VERSION_PATTERN = /\A(\d+(?:\.\d+)*)(?:-(\d+))?\z/
      TERM_PATTERN = /\A(~>|>=|<=|==|>|<|=)?\s*(\d\S*)\z/

      # @param version [String] a luarocks version ("3.4-1")
      # @param constraint [Hash] declaration constraint; "constraint" holds the expression
      # @return [Boolean]
      # @raise [InvalidConstraintError] if the expression does not parse
      # @raise [InvalidVersionError] if the version does not parse
      sig { override.params(version: String, constraint: T::Hash[String, T.untyped]).returns(T::Boolean) }
      def satisfies?(version, constraint)
        expression = constraint[CONSTRAINT_KEY].to_s.strip
        return true if expression.empty?

        key = comparison_key(version)
        expression.split(",").map(&:strip).all? { |term| term_satisfied?(key, term) }
      end

      # @param versions [Array<String>] luarocks versions
      # @return [Array<String>] ascending by dotted segments, then revision
      # @raise [InvalidVersionError] if any version does not parse
      sig { override.params(versions: T::Array[String]).returns(T::Array[String]) }
      def sort(versions)
        versions.sort_by { |version| comparison_key(version) }
      end

      private

      # @param key [Array] the candidate version's comparison key
      # @param term [String] one constraint term, e.g. ">= 3.0" or "~> 1.0.5"
      # @return [Boolean]
      # @raise [InvalidConstraintError] if the term does not parse
      sig { params(key: T::Array[T.untyped], term: String).returns(T::Boolean) }
      def term_satisfied?(key, term)
        match = TERM_PATTERN.match(term)
        raise InvalidConstraintError, "not a rockspec constraint: #{term.inspect}" unless match

        operator = match[1] || "=="
        bound = T.must(match[2])
        return pessimistic_match?(key, bound) if operator == "~>"

        comparison = T.must(key <=> comparison_key(bound))
        case operator
        when "==", "=" then comparison.zero?
        when ">=" then comparison >= 0
        when ">" then comparison.positive?
        when "<=" then comparison <= 0
        else comparison.negative?
        end
      end

      # Pessimistic constraint, rubygems-style: "~> 1.0.5" means >= 1.0.5 and
      # < 1.1; "~> 1.0" means >= 1.0 and < 2.0.
      #
      # @param key [Array] the candidate version's comparison key
      # @param bound [String] the pessimistic bound
      # @return [Boolean]
      sig { params(key: T::Array[T.untyped], bound: String).returns(T::Boolean) }
      def pessimistic_match?(key, bound)
        segments = comparison_key(bound).fetch(0)
        upper = segments.size > 1 ? segments[0..-2].to_a : segments.dup
        upper[-1] = upper.fetch(-1) + 1

        (key <=> comparison_key(bound)) >= 0 && T.must(key <=> [upper, 0]).negative?
      end

      # Comparison key: [release segments (trailing zeros stripped), revision].
      #
      # @param version [String]
      # @return [Array]
      # @raise [InvalidVersionError] if the version does not parse
      sig { params(version: String).returns(T::Array[T.untyped]) }
      def comparison_key(version)
        match = VERSION_PATTERN.match(version)
        raise InvalidVersionError, "not a luarocks version: #{version.inspect}" unless match

        segments = T.must(match[1]).split(".").map(&:to_i)
        segments.pop while segments.size > 1 && segments.last.to_i.zero?
        [segments, match[2].to_i]
      end
    end
  end
end

# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "version_scheme"

module Dev
  module Deps
    # Semver range semantics (:ficsit): node-style ranges over MAJOR.MINOR.PATCH
    # versions with optional prerelease tags.
    #
    # Supported range syntax — the subset ficsit.app mod constraints actually
    # use: caret ("^3.12.0"), tilde ("~1.2.3"), comparators (">=", ">", "<=",
    # "<", "="), bare exact versions, and space/comma-separated conjunction
    # (">=1.0.0 <2.0.0"). Prereleases order below their release
    # ("1.0.0-rc.1" < "1.0.0"), with semver's numeric-below-alphanumeric
    # identifier ordering.
    class SemverScheme < VersionScheme
      extend T::Sig

      # The range expression is not parseable semver range syntax.
      class InvalidConstraintError < VersionScheme::InvalidConstraintError; end
      # The version string is not a semver version.
      class InvalidVersionError < VersionScheme::InvalidVersionError; end

      # The constraint key carrying the range (the ficsit DSL's version:).
      CONSTRAINT_KEY = "version"

      # MAJOR.MINOR.PATCH with optional -prerelease and ignored +build.
      VERSION_PATTERN = /\A(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?\z/
      # Operator-prefixed term inside a range expression. Bounds may be partial
      # ("^3", ">=1.2"); missing segments are zero.
      TERM_PATTERN = /\A(\^|~|>=|<=|>|<|=)?(\d+(?:\.\d+){0,2}(?:-[0-9A-Za-z.-]+)?)\z/

      # @param version [String] a semver version
      # @param constraint [Hash] declaration constraint; "version" holds the range
      # @return [Boolean]
      # @raise [InvalidConstraintError] if the range does not parse
      # @raise [InvalidVersionError] if the version does not parse
      sig { override.params(version: String, constraint: T::Hash[String, T.untyped]).returns(T::Boolean) }
      def satisfies?(version, constraint)
        expression = constraint[CONSTRAINT_KEY].to_s.strip
        return true if expression.empty?

        key = comparison_key(version)
        terms(expression).all? { |term| term_satisfied?(key, term) }
      end

      # @param versions [Array<String>] semver versions
      # @return [Array<String>] ascending semver order
      # @raise [InvalidVersionError] if any version does not parse
      sig { override.params(versions: T::Array[String]).returns(T::Array[String]) }
      def sort(versions)
        versions.sort_by { |version| comparison_key(version) }
      end

      private

      # Split a range expression into [operator, release-triple, bound-key]
      # terms. Partial bounds pad with zeros; a bound's prerelease tag is kept
      # so terms like ">1.0.0-rc.1" compare at full precision.
      #
      # @param expression [String] e.g. "^3.12.0" or ">=1.0.0 <2.0.0"
      # @return [Array<[String, Array<Integer>, Array]>]
      # @raise [InvalidConstraintError] if any term does not parse
      sig { params(expression: String).returns(T::Array[[String, T::Array[Integer], T::Array[T.untyped]]]) }
      def terms(expression)
        expression.split(/[,\s]+/).map do |term|
          match = TERM_PATTERN.match(term)
          raise InvalidConstraintError, "not a semver range term: #{term.inspect}" unless match

          release, _, prerelease = T.must(match[2]).partition("-")
          triple = release.split(".").map(&:to_i)
          triple << 0 while triple.size < 3
          padded = triple.join(".") + (prerelease.empty? ? "" : "-#{prerelease}")
          [match[1] || "=", triple, comparison_key(padded)]
        end
      end

      # @param key [Array] the candidate version's comparison key
      # @param term [Array] [operator, release-triple, bound-key]
      # @return [Boolean]
      sig do
        params(
          key: T::Array[T.untyped],
          term: [String, T::Array[Integer], T::Array[T.untyped]],
        ).returns(T::Boolean)
      end
      def term_satisfied?(key, term)
        operator, triple, bound_key = term
        comparison = T.let(key <=> bound_key, Integer)
        case operator
        when "^" then comparison >= 0 && T.let(key <=> release_key(caret_upper(triple)), Integer).negative?
        when "~" then comparison >= 0 && T.let(key <=> release_key(tilde_upper(triple)), Integer).negative?
        when ">=" then comparison >= 0
        when ">" then comparison.positive?
        when "<=" then comparison <= 0
        when "<" then comparison.negative?
        else comparison.zero?
        end
      end

      # Exclusive upper bound for a caret range: the next release of the
      # leftmost non-zero segment ("^1.2.3" → 2.0.0, "^0.2.3" → 0.3.0,
      # "^0.0.3" → 0.0.4).
      #
      # @param bound [Array<Integer>] [major, minor, patch]
      # @return [Array<Integer>]
      sig { params(bound: T::Array[Integer]).returns(T::Array[Integer]) }
      def caret_upper(bound)
        major, minor, patch = bound
        return [T.must(major) + 1, 0, 0] if T.must(major).positive?
        return [0, T.must(minor) + 1, 0] if T.must(minor).positive?

        [0, 0, T.must(patch) + 1]
      end

      # Exclusive upper bound for a tilde range: the next minor ("~1.2.3" → 1.3.0).
      #
      # @param bound [Array<Integer>] [major, minor, patch]
      # @return [Array<Integer>]
      sig { params(bound: T::Array[Integer]).returns(T::Array[Integer]) }
      def tilde_upper(bound)
        major, minor, _patch = bound
        [T.must(major), T.must(minor) + 1, 0]
      end

      # Comparison key for a release triple (no prerelease): sorts above any
      # prerelease of the same triple.
      #
      # @param triple [Array<Integer>] [major, minor, patch]
      # @return [Array]
      sig { params(triple: T::Array[Integer]).returns(T::Array[T.untyped]) }
      def release_key(triple)
        [triple.fetch(0), triple.fetch(1), triple.fetch(2), 1, []]
      end

      # Semver comparison key: [major, minor, patch, release-flag, prerelease
      # identifiers]. The release flag puts releases (1) above prereleases (0);
      # prerelease identifiers compare numeric-below-alphanumeric per semver §11.
      #
      # @param version [String]
      # @return [Array]
      # @raise [InvalidVersionError] if the version does not parse
      sig { params(version: String).returns(T::Array[T.untyped]) }
      def comparison_key(version)
        match = VERSION_PATTERN.match(version)
        raise InvalidVersionError, "not a semver version: #{version.inspect}" unless match

        prerelease = match[4]
        identifiers = prerelease.to_s.split(".").map do |identifier|
          identifier.match?(/\A\d+\z/) ? [0, identifier.to_i, ""] : [1, 0, identifier]
        end
        [match[1].to_i, match[2].to_i, match[3].to_i, prerelease ? 0 : 1, identifiers]
      end
    end
  end
end

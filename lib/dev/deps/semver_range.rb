# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "requirement"

module Dev
  module Deps
    # node-style semver range syntax — the grammar ficsit.app writes mod
    # constraints in — translated into dev's Requirement. The subset SMR
    # uses: caret (`^3.12.0`), tilde (`~1.2.3`), comparators (`>=`, `>`,
    # `<=`, `<`, `=`), bare exact versions, and space- or comma-separated
    # conjunction (`>=1.0.0 <2.0.0`). Partial bounds (`^3`, `>=1.2`) pad
    # with zeros.
    #
    # A parser, stateless: the ficsit DSL keyword (`version:`) and the
    # ficsit repository's edge normalization both cross this boundary, and
    # nothing past it ever sees a caret.
    class SemverRange
      extend T::Sig

      # The expression is not a semver range this parser reads.
      class ParseError < StandardError; end

      # Operator-prefixed term; the version may be partial and may carry a
      # prerelease tag.
      TERM_PATTERN = /\A(\^|~|>=|<=|>|<|=)?(\d+(?:\.\d+){0,2}(?:-[0-9A-Za-z.-]+)?)\z/

      # @param expression [String] e.g. "^3.12.0", ">=1.0.0 <2.0.0", "1.2.3"
      # @return [Requirement] Exact for a bare version, Bounds otherwise
      # @raise [ParseError] if any term does not parse
      sig { params(expression: String).returns(Requirement) }
      def parse(expression)
        terms = expression.split(/[,\s]+/).reject(&:empty?)
        raise ParseError, "empty semver range" if terms.empty?

        bounds = terms.flat_map { |term| translate(term) }
        only = bounds.size == 1 ? bounds.fetch(0) : nil
        return Requirement::Exact.new(version: only.version) if only && only.operator == Requirement::EXACT

        Requirement::Bounds.new(terms: bounds)
      end

      private

      # @param term [String] one range term
      # @return [Array<Requirement::Bound>] the comparator terms it means
      # @raise [ParseError]
      sig { params(term: String).returns(T::Array[Requirement::Bound]) }
      def translate(term)
        match = TERM_PATTERN.match(term)
        raise ParseError, "#{term.inspect} is not a semver range term" unless match

        operator = match[1] || Requirement::EXACT
        release, _, prerelease = T.must(match[2]).partition("-")
        triple = release.split(".").map(&:to_i)
        triple << 0 while triple.size < 3
        lower = triple.join(".") + (prerelease.empty? ? "" : "-#{prerelease}")

        case operator
        when "^" then [bound(">=", lower), bound("<", caret_upper(triple).join("."))]
        when "~" then [bound(">=", lower), bound("<", tilde_upper(triple).join("."))]
        else [bound(operator, lower)]
        end
      end

      # @param operator [String] a Requirement comparator
      # @param version [String]
      # @return [Requirement::Bound]
      sig { params(operator: String, version: String).returns(Requirement::Bound) }
      def bound(operator, version)
        Requirement::Bound.new(operator: operator, version: version)
      end

      # Exclusive upper bound for a caret range: the next release of the
      # leftmost non-zero segment (`^1.2.3` → 2.0.0, `^0.2.3` → 0.3.0,
      # `^0.0.3` → 0.0.4).
      #
      # @param triple [Array<Integer>] [major, minor, patch]
      # @return [Array<Integer>]
      sig { params(triple: T::Array[Integer]).returns(T::Array[Integer]) }
      def caret_upper(triple)
        major, minor, patch = triple
        return [T.must(major) + 1, 0, 0] if T.must(major).positive?
        return [0, T.must(minor) + 1, 0] if T.must(minor).positive?

        [0, 0, T.must(patch) + 1]
      end

      # Exclusive upper bound for a tilde range: the next minor (`~1.2.3` → 1.3.0).
      #
      # @param triple [Array<Integer>] [major, minor, patch]
      # @return [Array<Integer>]
      sig { params(triple: T::Array[Integer]).returns(T::Array[Integer]) }
      def tilde_upper(triple)
        major, minor, _patch = triple
        [T.must(major), T.must(minor) + 1, 0]
      end
    end
  end
end

# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "version_scheme"

module Dev
  module Deps
    # PEP 440 constraint semantics (:pip): version specifiers over Python
    # package versions.
    #
    # Supported — the subset dependencies.rb pip declarations use: comparators
    # ("==", "!=", ">=", ">", "<=", "<"), compatible release ("~=2.0.3"),
    # wildcard equality ("==2.0.*"), bare exact versions, and comma-separated
    # conjunction. Version grammar: [epoch!]release[{a|b|rc}N][.postN][.devN];
    # local version labels ("+cpu") are accepted and ignored for ordering.
    # Deliberately NOT full PEP 440: arbitrary equality (===), post-release
    # exclusion nuances of ">V", and environment markers are out of scope —
    # they belong to a future dev-owned pip solve (docs/deps-architecture.md).
    class Pep440Scheme < VersionScheme
      extend T::Sig

      # The specifier is not parseable PEP 440 specifier syntax.
      class InvalidConstraintError < StandardError; end
      # The version string is not a PEP 440 version.
      class InvalidVersionError < StandardError; end

      # The constraint key carrying the specifier (the pip DSL's version:).
      CONSTRAINT_KEY = "version"

      VERSION_PATTERN = /
        \A
        (?:(\d+)!)?                # epoch
        (\d+(?:\.\d+)*)            # release segments
        (?:[._-]?(a|b|rc|alpha|beta|c|pre|preview)[._-]?(\d*))?  # prerelease
        (?:[._-]?post[._-]?(\d*))? # post release
        (?:[._-]?dev[._-]?(\d*))?  # dev release
        (?:\+[0-9a-z.]+)?          # local version label (ignored)
        \z
      /xi

      TERM_PATTERN = /\A(==|!=|>=|<=|>|<|~=)?\s*(\S+)\z/

      # Prerelease phase ranks; canonical spellings and PEP 440 aliases.
      PHASE_RANKS = T.let(
        { "a" => 0, "alpha" => 0, "b" => 1, "beta" => 1, "c" => 2, "pre" => 2, "preview" => 2, "rc" => 2 }.freeze,
        T::Hash[String, Integer],
      )

      # @param version [String] a PEP 440 version
      # @param constraint [Hash] declaration constraint; "version" holds the specifier
      # @return [Boolean]
      # @raise [InvalidConstraintError] if the specifier does not parse
      # @raise [InvalidVersionError] if the version does not parse
      sig { override.params(version: String, constraint: T::Hash[String, T.untyped]).returns(T::Boolean) }
      def satisfies?(version, constraint)
        expression = constraint[CONSTRAINT_KEY].to_s.strip
        return true if expression.empty?

        expression.split(",").map(&:strip).all? { |term| term_satisfied?(version, term) }
      end

      # @param versions [Array<String>] PEP 440 versions
      # @return [Array<String>] ascending PEP 440 order (dev < pre < release < post)
      # @raise [InvalidVersionError] if any version does not parse
      sig { override.params(versions: T::Array[String]).returns(T::Array[String]) }
      def sort(versions)
        versions.sort_by { |version| comparison_key(version) }
      end

      private

      # @param version [String] the candidate version
      # @param term [String] one specifier term, e.g. ">=2.0" or "==2.0.*"
      # @return [Boolean]
      # @raise [InvalidConstraintError] if the term does not parse
      sig { params(version: String, term: String).returns(T::Boolean) }
      def term_satisfied?(version, term)
        match = TERM_PATTERN.match(term)
        raise InvalidConstraintError, "not a PEP 440 specifier: #{term.inspect}" unless match

        operator = match[1] || "=="
        bound = T.must(match[2])
        raise InvalidConstraintError, "not a PEP 440 specifier: #{term.inspect}" if bound.start_with?("=")

        return wildcard_match?(version, bound.delete_suffix(".*")) == (operator == "==") if bound.end_with?(".*")
        return compatible_release?(version, bound) if operator == "~="

        comparison = T.must(comparison_key(version) <=> comparison_key(bound))
        case operator
        when "==" then comparison.zero?
        when "!=" then !comparison.zero?
        when ">=" then comparison >= 0
        when ">" then comparison.positive?
        when "<=" then comparison <= 0
        else comparison.negative?
        end
      end

      # "==X.Y.*": the version's release segments start with the prefix's.
      #
      # @param version [String] the candidate version
      # @param prefix [String] the wildcard bound without its ".*"
      # @return [Boolean]
      sig { params(version: String, prefix: String).returns(T::Boolean) }
      def wildcard_match?(version, prefix)
        prefix_release = release_segments(prefix)
        release = release_segments(version)
        release = release + [0] * (prefix_release.size - release.size) if release.size < prefix_release.size
        release.first(prefix_release.size) == prefix_release
      end

      # "~=X.Y[.Z]": at least the bound, and matching the bound with its last
      # release segment made a wildcard (~=2.4.5 means >=2.4.5, ==2.4.*).
      #
      # @param version [String] the candidate version
      # @param bound [String] the compatible-release bound
      # @return [Boolean]
      # @raise [InvalidConstraintError] if the bound has fewer than two segments
      sig { params(version: String, bound: String).returns(T::Boolean) }
      def compatible_release?(version, bound)
        segments = release_segments(bound)
        raise InvalidConstraintError, "~= needs at least two release segments: #{bound.inspect}" if segments.size < 2

        prefix = segments[0..-2].to_a.join(".")
        (comparison_key(version) <=> comparison_key(bound)) >= 0 && wildcard_match?(version, prefix)
      end

      # @param version [String]
      # @return [Array<Integer>] the release segments, trailing zeros stripped
      # @raise [InvalidVersionError] if the version does not parse
      sig { params(version: String).returns(T::Array[Integer]) }
      def release_segments(version)
        match = VERSION_PATTERN.match(version)
        raise InvalidVersionError, "not a PEP 440 version: #{version.inspect}" unless match

        T.must(match[2]).split(".").map(&:to_i)
      end

      # PEP 440 comparison key, mirroring pip's _cmpkey: [epoch, release
      # (trailing zeros stripped), pre-key, post-key, dev-key]. A dev release
      # with no prerelease sorts below any prerelease of the same release.
      #
      # @param version [String]
      # @return [Array]
      # @raise [InvalidVersionError] if the version does not parse
      sig { params(version: String).returns(T::Array[T.untyped]) }
      def comparison_key(version)
        match = VERSION_PATTERN.match(version)
        raise InvalidVersionError, "not a PEP 440 version: #{version.inspect}" unless match

        epoch = match[1].to_i
        release = T.must(match[2]).split(".").map(&:to_i)
        release.pop while release.size > 1 && release.last.to_i.zero?

        phase, phase_number, post, dev = match[3], match[4], match[5], match[6]
        pre_key = if phase
          [PHASE_RANKS.fetch(T.must(phase).downcase), phase_number.to_i]
        elsif post.nil? && dev
          [-1] # dev-only releases sort below every prerelease
        else
          [3]
        end
        post_key = post ? [0, post.to_i] : [-1]
        dev_key = dev ? [0, dev.to_i] : [1]

        [epoch, release, pre_key, post_key, dev_key]
      end
    end
  end
end

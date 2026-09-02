# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "version_scheme"

module Dev
  module Deps
    # RubyGems constraint semantics (:bundler): Gem::Requirement syntax
    # ("~> 1.17", ">= 1.0, < 2.0", exact pins) and Gem::Version ordering.
    #
    # A thin wrapper over rubygems' own classes — the authority on its own
    # version grammar. Comma-separated requirements are conjunctive, matching
    # Gemfile semantics.
    class GemScheme < VersionScheme
      extend T::Sig

      # The requirement string is not valid Gem::Requirement syntax.
      class InvalidConstraintError < VersionScheme::InvalidConstraintError; end
      # The version string is not a valid Gem::Version.
      class InvalidVersionError < VersionScheme::InvalidVersionError; end

      # The constraint key carrying the version requirement (the gem DSL's
      # positional requirement lands under "version").
      CONSTRAINT_KEY = "version"

      # @param version [String] a gem version string
      # @param constraint [Hash] declaration constraint; only "version" is a
      #   version requirement (other keys — require:, git: — are gem options)
      # @return [Boolean]
      # @raise [InvalidConstraintError] if the requirement does not parse
      # @raise [InvalidVersionError] if the version does not parse
      sig { override.params(version: String, constraint: T::Hash[String, T.untyped]).returns(T::Boolean) }
      def satisfies?(version, constraint)
        expression = constraint[CONSTRAINT_KEY].to_s.strip
        return true if expression.empty?

        requirement(expression).satisfied_by?(gem_version(version))
      end

      # @param versions [Array<String>] gem version strings
      # @return [Array<String>] ascending by Gem::Version ordering
      # @raise [InvalidVersionError] if any version does not parse
      sig { override.params(versions: T::Array[String]).returns(T::Array[String]) }
      def sort(versions)
        versions.sort_by { |version| gem_version(version) }
      end

      private

      # @param expression [String] comma-separated requirement terms
      # @return [Gem::Requirement]
      # @raise [InvalidConstraintError] if any term does not parse
      sig { params(expression: String).returns(Gem::Requirement) }
      def requirement(expression)
        Gem::Requirement.new(expression.split(",").map(&:strip))
      rescue Gem::Requirement::BadRequirementError
        raise InvalidConstraintError, "not a rubygems requirement: #{expression.inspect}"
      end

      # @param version [String]
      # @return [Gem::Version]
      # @raise [InvalidVersionError] if the version does not parse
      sig { params(version: String).returns(Gem::Version) }
      def gem_version(version)
        Gem::Version.new(version)
      rescue ArgumentError
        raise InvalidVersionError, "not a rubygems version: #{version.inspect}"
      end
    end
  end
end

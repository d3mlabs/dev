# typed: strict
# frozen_string_literal: true

require_relative "range_scheme"
require_relative "requirement"

module Dev
  module Deps
    # RubyGems requirement semantics (:bundler, :ruby): the channel dev's
    # language is borrowed from, so the requirement translates to a
    # Gem::Requirement term for term (`render`) and Gem::Version orders.
    #
    # bundler is a tool-solved channel: the Locker hands `render`'s output
    # to the Gemfile and bundler picks; `satisfies?` then confirms the
    # lock's singleton choice. `ruby` is dev-picked: the d3mlabs tap's
    # `ruby@X.Y.Z` family is ranged over with these same rules.
    class GemScheme < RangeScheme
      extend T::Sig

      # A requirement version rubygems cannot read.
      class InvalidRequirementError < VersionScheme::InvalidRequirementError; end
      # The version string is not a valid Gem::Version.
      class InvalidVersionError < VersionScheme::InvalidVersionError; end

      # @param version [PackageVersion] a candidate; only its version string matters
      # @param requirement [Requirement]
      # @return [Boolean] rubygems' own verdict
      # @raise [InvalidRequirementError] if a requirement version does not parse
      # @raise [InvalidVersionError] if the version does not parse
      sig { override.params(version: PackageVersion, requirement: Requirement).returns(T::Boolean) }
      def satisfies?(version, requirement)
        render(requirement).satisfied_by?(comparison_key(version.version))
      end

      # The requirement in the tool's own type — identity, term for term;
      # the empty ask is rubygems' default (`>= 0`).
      #
      # @param requirement [Requirement]
      # @return [Gem::Requirement]
      # @raise [InvalidRequirementError] if a requirement version does not parse
      sig { params(requirement: Requirement).returns(Gem::Requirement) }
      def render(requirement)
        Gem::Requirement.new(requirement.terms.map(&:to_s))
      rescue Gem::Requirement::BadRequirementError
        raise InvalidRequirementError, "not a rubygems requirement: #{requirement.to_s.inspect}"
      end

      protected

      # @param coordinate [String]
      # @return [Gem::Version]
      # @raise [InvalidVersionError] if the version does not parse
      sig { override.params(coordinate: String).returns(Gem::Version) }
      def comparison_key(coordinate)
        Gem::Version.new(coordinate)
      rescue ArgumentError
        raise InvalidVersionError, "not a rubygems version: #{coordinate.inspect}"
      end
    end
  end
end

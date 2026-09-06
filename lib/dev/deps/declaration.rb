# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module Dev
  module Deps
    # The shared atom of the deps domain: "package NAME of INTEGRATION, under
    # CONSTRAINT". Stated by whoever authored the thing — a project's
    # dependencies.rb row (which wraps it in a ScopedDeclaration with its
    # install context) or an upstream manifest (a PackageVersion's declared
    # dependencies, reported by the integration's Repository).
    #
    # Context-free by type: where and when a dependency installs (group, host,
    # env) is a property of the path the resolver walked to reach it, never of
    # the declaration itself. The same upstream declaration reached via two
    # parents inherits two different contexts — see Scope and
    # ScopedDeclaration.
    #
    # The constraint is always in dev's shape: a hash whose keys are owned by
    # the integration's VersionScheme (e.g. { "version" => "^3.6" },
    # { "tag" => "v1.0" }); {} means unconstrained — a present empty form,
    # never nil. Repositories normalize upstream syntax into this shape at
    # construction, so constraints cross the system boundary exactly once.
    #
    # See docs/deps-architecture.md for the ontology this belongs to.
    class Declaration
      extend T::Sig

      # @return [String] the package's name within its integration's universe
      sig { returns(String) }
      attr_reader :name

      # @return [Symbol] the integration whose universe the name lives in
      sig { returns(Symbol) }
      attr_reader :integration

      # @return [Hash{String => Object}] version constraint in dev's shape;
      #   {} means unconstrained
      sig { returns(T::Hash[String, T.untyped]) }
      attr_reader :constraint

      # @param name [String] the package's name
      # @param integration [Symbol] :bundler, :ficsit, :cmake, …
      # @param constraint [Hash{String => Object}] dev-shaped constraint;
      #   defaults to {} (unconstrained)
      sig { params(name: String, integration: Symbol, constraint: T::Hash[String, T.untyped]).void }
      def initialize(name:, integration:, constraint: {})
        @name = name
        @integration = integration
        @constraint = T.let(constraint.dup.freeze, T::Hash[String, T.untyped])
        freeze
      end

      # @param other [Object]
      # @return [Boolean] whether other states the same declaration
      sig { params(other: Object).returns(T::Boolean) }
      def ==(other)
        return false unless other.is_a?(Declaration)

        [name, integration, constraint] == [other.name, other.integration, other.constraint]
      end
      alias_method :eql?, :==

      # @return [Integer] hash code, so declarations work as Hash keys
      sig { returns(Integer) }
      def hash
        [self.class, name, integration, constraint].hash
      end
    end
  end
end

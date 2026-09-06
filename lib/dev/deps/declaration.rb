# typed: true
# frozen_string_literal: true

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
    # No sorbet-runtime here: this file rides the dependencies.rb load chain
    # (deps.rb -> config.rb -> dsl.rb), which must work under bare Ruby before
    # bundler provisions any gem.
    #
    # See docs/deps-architecture.md for the ontology this belongs to.
    class Declaration
      # @return [String] the package's name within its integration's universe
      attr_reader :name

      # @return [Symbol] the integration whose universe the name lives in
      attr_reader :integration

      # @return [Hash{String => Object}] version constraint in dev's shape;
      #   {} means unconstrained
      attr_reader :constraint

      # @param name [String] the package's name
      # @param integration [Symbol] :bundler, :ficsit, :cmake, …
      # @param constraint [Hash{String => Object}] dev-shaped constraint;
      #   defaults to {} (unconstrained)
      def initialize(name:, integration:, constraint: {})
        @name = name
        @integration = integration
        @constraint = constraint.dup.freeze
        freeze
      end

      # @param other [Object]
      # @return [Boolean] whether other states the same declaration
      def ==(other)
        return false unless other.is_a?(Declaration)

        [name, integration, constraint] == [other.name, other.integration, other.constraint]
      end
      alias_method :eql?, :==

      # @return [Integer] hash code, so declarations work as Hash keys
      def hash
        [self.class, name, integration, constraint].hash
      end
    end
  end
end

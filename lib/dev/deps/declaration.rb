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
    # Only version-shaped keys live here: source coordinates are the `source`
    # field, and install instructions are ScopedDeclaration's materialization.
    #
    # source is on the atom (not ScopedDeclaration) because both authors can
    # legitimately state it: an upstream manifest edge can point at a source
    # coordinate (cargo-style git deps) just as a project row can. It is
    # identity-shaping — Resolver#package_id reads it onto PackageId#source.
    #
    # revision is the other way to ask: an address into an integration's
    # continuous space (a git commit SHA, an exact Xcode version) instead of a
    # selection over its discrete published universe. An address forgoes
    # resolution — the Resolver hands it to Repository#at and no scheme runs —
    # so a revision alongside version constraints is a contradiction and is
    # rejected at construction. The spelling is the ecosystem's canonical one
    # (dev's only operation on a revision is equality, in conflict rejection),
    # validated by the DSL verb that mints it.
    #
    # See docs/deps-architecture.md for the ontology this belongs to.
    class Declaration
      extend T::Sig

      # A declaration states both an address (revision) and a selection
      # (version constraints) — asking dev to resolve what the author
      # already forewent resolving.
      class RevisionWithConstraintError < StandardError; end

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

      # @return [String, nil] source coordinate locating the package's
      #   universe (a git remote URL, an "owner/repo" slug, a brew tap, a
      #   Steam app id); nil for registry-backed integrations, where the name
      #   alone identifies the package
      sig { returns(T.nilable(String)) }
      attr_reader :source

      # @return [String, nil] address into the integration's continuous space
      #   (a full git commit SHA, an exact Xcode version); nil for
      #   constraint-shaped asks, which select over the published universe
      sig { returns(T.nilable(String)) }
      attr_reader :revision

      # @param name [String] the package's name
      # @param integration [Symbol] :bundler, :ficsit, :cmake, …
      # @param constraint [Hash{String => Object}] dev-shaped constraint;
      #   defaults to {} (unconstrained)
      # @param source [String, nil] source coordinate; defaults to nil
      # @param revision [String, nil] addressable revision; defaults to nil
      # @raise [RevisionWithConstraintError] if both a revision and version
      #   constraints are stated
      sig do
        params(
          name: String,
          integration: Symbol,
          constraint: T::Hash[String, T.untyped],
          source: T.nilable(String),
          revision: T.nilable(String),
        ).void
      end
      def initialize(name:, integration:, constraint: {}, source: nil, revision: nil)
        if revision && !constraint.empty?
          raise RevisionWithConstraintError,
            "#{integration}/#{name} pins revision #{revision.inspect} and constrains " \
              "#{constraint.inspect} — an address forgoes resolution, a constraint asks for it"
        end

        @name = name
        @integration = integration
        @constraint = T.let(constraint.dup.freeze, T::Hash[String, T.untyped])
        @source = source
        @revision = revision
        freeze
      end

      # @param other [Object]
      # @return [Boolean] whether other states the same declaration
      sig { params(other: Object).returns(T::Boolean) }
      def ==(other)
        return false unless other.is_a?(Declaration)

        [name, integration, constraint, source, revision] ==
          [other.name, other.integration, other.constraint, other.source, other.revision]
      end
      alias_method :eql?, :==

      # @return [Integer] hash code, so declarations work as Hash keys
      sig { returns(Integer) }
      def hash
        [self.class, name, integration, constraint, source, revision].hash
      end
    end
  end
end

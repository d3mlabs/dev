# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "../value_equality"

module Dev
  module Deps
    # The shared atom of the deps domain: "package NAME of INTEGRATION,
    # under CONSTRAINT". Stated by a project's dependencies.rb row (wrapped
    # in a ScopedDeclaration with its install context) or by an upstream
    # manifest.
    #
    # Context-free by type: where and when a dependency installs (group,
    # host, env) is a property of the path the resolver walked to reach it,
    # never of the declaration itself.
    #
    # The constraint is always in dev's shape: a hash whose keys are owned
    # by the integration's VersionScheme (`{ "version" => "^3.6" }`, `{
    # "tag" => "v1.0" }`); `{}` means unconstrained. Repositories normalize
    # upstream syntax into this shape at construction. Source coordinates
    # are the `source` field; install instructions are ScopedDeclaration's
    # materialization.
    #
    # `revision` is the other way to ask: an address into an integration's
    # continuous space (a git commit SHA, an exact Xcode version) instead of
    # a selection over its published universe. An address forgoes
    # resolution, so a revision alongside version constraints is rejected
    # at construction.
    #
    # See docs/deps-architecture.md for the ontology this belongs to.
    class Declaration
      extend T::Sig
      include Dev::ValueEquality::Derived

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

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [name, integration, constraint, source, revision]
      end
    end
  end
end

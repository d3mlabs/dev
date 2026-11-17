# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "../value_equality"
require_relative "requirement"

module Dev
  module Deps
    # The shared atom of the deps domain: "package NAME of INTEGRATION,
    # under REQUIREMENT". Stated by a project's dependencies.rb row (wrapped
    # in a ScopedDeclaration with its install context) or by an upstream
    # manifest.
    #
    # Context-free by type: where and when a dependency installs (group,
    # host, env) is a property of the path the resolver walked to reach it,
    # never of the declaration itself.
    #
    # The requirement is always in dev's one language (Requirement): a
    # predicate over the published universe the integration's VersionScheme
    # evaluates or translates; `Requirement::Any` means unconstrained.
    # Repositories normalize upstream syntax into it at construction.
    # Source coordinates are the `source` field; install instructions are
    # ScopedDeclaration's materialization; what remains of a row — options
    # in the integration's own vocabulary that select nothing (a gem's
    # `require:`, `git:`) — rides `options` for the integration to forward.
    #
    # `revision` is the other way to ask: an address into an integration's
    # continuous space (a git commit SHA, an exact Xcode version) instead of
    # a selection over its published universe. An address forgoes
    # resolution, so a revision alongside a requirement is rejected at
    # construction.
    #
    # See docs/deps-architecture.md for the ontology this belongs to.
    class Declaration
      extend T::Sig
      include Dev::ValueEquality::Derived

      # A declaration states both an address (revision) and a selection
      # (a requirement, or options the universe would be asked under) —
      # asking dev to resolve what the author already forewent resolving.
      class RevisionWithRequirementError < StandardError; end

      # @return [String] the package's name within its integration's universe
      sig { returns(String) }
      attr_reader :name

      # @return [Symbol] the integration whose universe the name lives in
      sig { returns(Symbol) }
      attr_reader :integration

      # @return [Requirement] what is asked of the package's versions;
      #   Requirement::Any means unconstrained
      sig { returns(Requirement) }
      attr_reader :requirement

      # @return [Hash{String => Object}] the row's integration options, in
      #   the integration's vocabulary, forwarded verbatim; {} when none
      sig { returns(T::Hash[String, T.untyped]) }
      attr_reader :options

      # @return [String, nil] source coordinate locating the package's
      #   universe (a git remote URL, an "owner/repo" slug, a brew tap, a
      #   Steam app and branch); nil for registry-backed integrations, where
      #   the name alone identifies the package
      sig { returns(T.nilable(String)) }
      attr_reader :source

      # @return [String, nil] address into the integration's continuous space
      #   (a full git commit SHA, an exact Xcode version); nil for
      #   requirement-shaped asks, which select over the published universe
      sig { returns(T.nilable(String)) }
      attr_reader :revision

      # @param name [String] the package's name
      # @param integration [Symbol] :bundler, :ficsit, :cmake, …
      # @param requirement [Requirement] defaults to Any (unconstrained)
      # @param options [Hash{String => Object}] integration options; defaults to {}
      # @param source [String, nil] source coordinate; defaults to nil
      # @param revision [String, nil] addressable revision; defaults to nil
      # @raise [RevisionWithRequirementError] if both a revision and a
      #   requirement (or options) are stated
      sig do
        params(
          name: String,
          integration: Symbol,
          requirement: Requirement,
          options: T::Hash[String, T.untyped],
          source: T.nilable(String),
          revision: T.nilable(String),
        ).void
      end
      def initialize(name:, integration:, requirement: Requirement::Any.new, options: {}, source: nil, revision: nil)
        if revision && (!requirement.any? || !options.empty?)
          asked = requirement.any? ? options.inspect : requirement.to_s.inspect
          raise RevisionWithRequirementError,
            "#{integration}/#{name} pins revision #{revision.inspect} and asks #{asked} — " \
              "an address forgoes resolution, a requirement asks for it"
        end

        @name = name
        @integration = integration
        @requirement = requirement
        @options = T.let(options.dup.freeze, T::Hash[String, T.untyped])
        @source = source
        @revision = revision
        freeze
      end

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [name, integration, requirement, options, source, revision]
      end
    end
  end
end

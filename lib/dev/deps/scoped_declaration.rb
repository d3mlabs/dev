# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "declaration"
require_relative "scope"

module Dev
  module Deps
    # A Declaration married to the context it resolves under: fact-in-context.
    #
    # Project rows are born with explicit context (the DSL group's axes);
    # transitive declarations get the parent's Scope stamped by the Resolver
    # at walk time — context is a property of the path, which is why the bare
    # Declaration cannot carry it. Composition, deliberately not a subclass: a
    # ScopedDeclaration must never pass where a context-free Declaration is
    # expected (the facts side of the domain), and value equality across an
    # inheritance boundary is a trap.
    #
    # platform, post_install, and materialization ride here rather than in
    # Scope because they are per-row and do not inherit: platforms union per
    # package across the declaring groups (Resolver#declared_platforms), hooks
    # run only for the row that declared them, and install instructions
    # describe how THIS project consumes the package. They also cannot live on
    # Declaration: the atom is shared with repository-reported manifest edges,
    # and no upstream manifest states where you install something.
    class ScopedDeclaration
      extend T::Sig

      # @return [Declaration] the ask: name + integration + constraint + source
      sig { returns(Declaration) }
      attr_reader :declaration

      # @return [Scope] the context the ask resolves under
      sig { returns(Scope) }
      attr_reader :scope

      # @return [String, nil] artifact variant this row targets (e.g.
      #   "LinuxServer"); nil lets the integration pick its default
      sig { returns(T.nilable(String)) }
      attr_reader :platform

      # @return [Proc, Array<Proc>, nil] callable(s) run after the dep is
      #   fetched; never serialized to the lockfile
      sig { returns(T.nilable(T.any(Proc, T::Array[Proc]))) }
      attr_reader :post_install

      # @return [Hash{String => Object}] install instructions for this row
      #   (install_dir, an asset glob, a build recipe); merged into the minted
      #   pin's metadata by the Resolver, never seen by a Repository. {} means
      #   the integration's tool owns layout.
      sig { returns(T::Hash[String, T.untyped]) }
      attr_reader :materialization

      # @param declaration [Declaration] the ask
      # @param scope [Scope] resolution context; defaults to the default scope
      # @param platform [String, nil] targeted artifact variant
      # @param post_install [Proc, Array<Proc>, nil] post-fetch hook(s)
      # @param materialization [Hash{String => Object}] install instructions;
      #   defaults to {} (tool-owned layout)
      sig do
        params(
          declaration: Declaration,
          scope: Scope,
          platform: T.nilable(String),
          post_install: T.nilable(T.any(Proc, T::Array[Proc])),
          materialization: T::Hash[String, T.untyped],
        ).void
      end
      def initialize(declaration:, scope: Scope.new, platform: nil, post_install: nil, materialization: {})
        @declaration = declaration
        @scope = scope
        @platform = platform
        @post_install = post_install
        @materialization = T.let(materialization.dup.freeze, T::Hash[String, T.untyped])
        freeze
      end

      # @return [String] the ask's package name (delegated)
      sig { returns(String) }
      def name = declaration.name

      # @return [Symbol] the ask's integration (delegated)
      sig { returns(Symbol) }
      def integration = declaration.integration

      # @return [Hash{String => Object}] the ask's constraint (delegated)
      sig { returns(T::Hash[String, T.untyped]) }
      def constraint = declaration.constraint

      # @return [String, nil] the ask's source coordinate (delegated)
      sig { returns(T.nilable(String)) }
      def source = declaration.source

      # @return [String, nil] the ask's addressable revision (delegated)
      sig { returns(T.nilable(String)) }
      def revision = declaration.revision

      # @param other [Object]
      # @return [Boolean] whether other is the same ask under the same context
      sig { params(other: Object).returns(T::Boolean) }
      def ==(other)
        return false unless other.is_a?(ScopedDeclaration)

        [declaration, scope, platform, post_install, materialization] ==
          [other.declaration, other.scope, other.platform, other.post_install, other.materialization]
      end
      alias_method :eql?, :==

      # @return [Integer] hash code
      sig { returns(Integer) }
      def hash
        [self.class, declaration, scope, platform, post_install, materialization].hash
      end
    end
  end
end

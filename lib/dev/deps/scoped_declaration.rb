# typed: true
# frozen_string_literal: true

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
    # platform and post_install ride here rather than in Scope because they
    # are per-row and do not inherit: platforms union per package across the
    # declaring groups (Resolver#declared_platforms), and hooks run only for
    # the row that declared them.
    #
    # No sorbet-runtime here: this file rides the dependencies.rb load chain,
    # which must work under bare Ruby before bundler provisions any gem.
    class ScopedDeclaration
      # @return [Declaration] the ask: name + integration + constraint
      attr_reader :declaration

      # @return [Scope] the context the ask resolves under
      attr_reader :scope

      # @return [String, nil] artifact variant this row targets (e.g.
      #   "LinuxServer"); nil lets the integration pick its default
      attr_reader :platform

      # @return [Proc, Array<Proc>, nil] callable(s) run after the dep is
      #   fetched; never serialized to the lockfile
      attr_reader :post_install

      # @param declaration [Declaration] the ask
      # @param scope [Scope] resolution context; defaults to the default scope
      # @param platform [String, nil] targeted artifact variant
      # @param post_install [Proc, Array<Proc>, nil] post-fetch hook(s)
      def initialize(declaration:, scope: Scope.new, platform: nil, post_install: nil)
        @declaration = declaration
        @scope = scope
        @platform = platform
        @post_install = post_install
        freeze
      end

      # @return [String] the ask's package name (delegated)
      def name = declaration.name

      # @return [Symbol] the ask's integration (delegated)
      def integration = declaration.integration

      # @return [Hash{String => Object}] the ask's constraint (delegated)
      def constraint = declaration.constraint

      # @param other [Object]
      # @return [Boolean] whether other is the same ask under the same context
      def ==(other)
        return false unless other.is_a?(ScopedDeclaration)

        [declaration, scope, platform, post_install] ==
          [other.declaration, other.scope, other.platform, other.post_install]
      end
      alias_method :eql?, :==

      # @return [Integer] hash code
      def hash
        [self.class, declaration, scope, platform, post_install].hash
      end
    end
  end
end

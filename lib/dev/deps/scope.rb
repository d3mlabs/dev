# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module Dev
  module Deps
    # The resolution context a declaration is scoped under: which group asked
    # for it, and where/when it installs. Rides the resolve walk parent ->
    # child as a single unit — a dep only needed in one group/host/env can't
    # need its transitive closure anywhere else — which is why these three
    # axes live together and platform does not (platforms union per package
    # across declaring groups instead of inheriting).
    #
    # host and env use nil as their all-encompassing empty form ("installs
    # everywhere"), matching the declaration axes documented in the README;
    # group always names a purpose and defaults to :app.
    class Scope
      extend T::Sig

      # @return [Symbol] purpose the dep was declared for (:app, :test, :build, …)
      sig { returns(Symbol) }
      attr_reader :group

      # @return [Symbol, nil] host OS the dep installs on (:darwin / :linux);
      #   nil means all hosts
      sig { returns(T.nilable(Symbol)) }
      attr_reader :host

      # @return [String, nil] execution context the dep is for ("ci" / "dev");
      #   nil means all envs
      sig { returns(T.nilable(String)) }
      attr_reader :env

      # @param group [Symbol] purpose group; defaults to :app
      # @param host [Symbol, String, nil] host OS, coerced to a Symbol
      # @param env [String, Symbol, nil] environment name, coerced to a String
      sig do
        params(
          group: Symbol,
          host: T.nilable(T.any(Symbol, String)),
          env: T.nilable(T.any(String, Symbol)),
        ).void
      end
      def initialize(group: :app, host: nil, env: nil)
        @group = group
        @host = T.let(host&.to_sym, T.nilable(Symbol))
        @env = T.let(env&.to_s, T.nilable(String))
        freeze
      end

      # The context this scope resolves under when reached beneath a parent
      # — the Resolver's walk from a using declaration into the needs its
      # integration's manifest exports. Purpose is the consumer's, so the
      # group is the parent's; on the host and env axes the result is what
      # both agree on: an axis one side leaves open takes the other's value,
      # and a value both state must match. nil when they disagree — no
      # machine satisfies both, so a need scoped this way is simply not
      # needed beneath that parent (a darwin-only tool under a linux-only
      # use). A scope with nothing pinned narrows nothing: the parent's
      # context is inherited wholesale.
      #
      # @param parent [Scope] the declaring parent's context
      # @return [Scope, nil] the narrowed context, or nil when the two are
      #   disjoint on some axis
      sig { params(parent: Scope).returns(T.nilable(Scope)) }
      def under(parent)
        return nil if disjoint?(host, parent.host) || disjoint?(env, parent.env)

        Scope.new(group: parent.group, host: host || parent.host, env: env || parent.env)
      end

      # Install-scoping projection stamped onto minted pins, so host/env land
      # in the lockfile and the installer can filter on them. group is not
      # projected — it is a first-class Dependency field.
      #
      # @return [Hash{String => String}] host/env keys, present only when pinned
      sig { returns(T::Hash[String, String]) }
      def to_metadata
        meta = T.let({}, T::Hash[String, String])
        h = host
        e = env
        meta["host"] = h.to_s if h
        meta["env"] = e if e
        meta
      end

      # @param other [Object]
      # @return [Boolean] whether other is the same context
      sig { params(other: Object).returns(T::Boolean) }
      def ==(other)
        return false unless other.is_a?(Scope)

        [group, host, env] == [other.group, other.host, other.env]
      end
      alias_method :eql?, :==

      # @return [Integer] hash code, so scopes work as Hash keys
      sig { returns(Integer) }
      def hash
        [self.class, group, host, env].hash
      end

      private

      # Two values of one axis disagree only when both are stated and differ;
      # an open side (nil) agrees with anything.
      #
      # @param mine [Symbol, String, nil] this scope's value
      # @param theirs [Symbol, String, nil] the other scope's value
      # @return [Boolean]
      sig do
        params(
          mine: T.nilable(T.any(Symbol, String)),
          theirs: T.nilable(T.any(Symbol, String)),
        ).returns(T::Boolean)
      end
      def disjoint?(mine, theirs)
        !mine.nil? && !theirs.nil? && mine != theirs
      end
    end
  end
end

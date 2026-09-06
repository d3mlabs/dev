# typed: true
# frozen_string_literal: true

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
    #
    # No sorbet-runtime here: this file rides the dependencies.rb load chain,
    # which must work under bare Ruby before bundler provisions any gem.
    class Scope
      # @return [Symbol] purpose the dep was declared for (:app, :test, :build, …)
      attr_reader :group

      # @return [Symbol, nil] host OS the dep installs on (:darwin / :linux);
      #   nil means all hosts
      attr_reader :host

      # @return [String, nil] execution context the dep is for ("ci" / "dev");
      #   nil means all envs
      attr_reader :env

      # @param group [Symbol] purpose group; defaults to :app
      # @param host [Symbol, String, nil] host OS, coerced to a Symbol
      # @param env [String, Symbol, nil] environment name, coerced to a String
      def initialize(group: :app, host: nil, env: nil)
        @group = group
        @host = host&.to_sym
        @env = env&.to_s
        freeze
      end

      # Install-scoping projection stamped onto minted pins, so host/env land
      # in the lockfile and the installer can filter on them. group is not
      # projected — it is a first-class Dependency field.
      #
      # @return [Hash{String => String}] host/env keys, present only when pinned
      def to_metadata
        meta = {}
        meta["host"] = host.to_s if host
        meta["env"] = env if env
        meta
      end

      # @param other [Object]
      # @return [Boolean] whether other is the same context
      def ==(other)
        return false unless other.is_a?(Scope)

        [group, host, env] == [other.group, other.host, other.env]
      end
      alias_method :eql?, :==

      # @return [Integer] hash code, so scopes work as Hash keys
      def hash
        [self.class, group, host, env].hash
      end
    end
  end
end

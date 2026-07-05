# frozen_string_literal: true

module Dev
  module Deps
    # A declared dependency before resolution.
    #
    # Represents what the user declares in the DSL — a name, integration type,
    # version constraint, and group. The Resolver consumes these and produces
    # fully resolved Dependency objects.
    #
    # The four declaration axes (see README "Dependency axes"):
    # - group:        purpose (e.g. :app, :test, :build — user-defined)
    # - env:          execution context the dep is for ("ci" / "dev"), or nil for all
    # - host:         OS of the machine the dep installs on (:darwin / :linux), or nil for all
    # - platform:     what artifact variant the dep targets (e.g. "LinuxServer"), or nil
    #                 to let the integration pick its default. Multi-arch integrations
    #                 (ficsit) resolve a dep for the union of the platforms of every
    #                 group that declares it.
    #
    # env and host are facts about *where/when the dep installs*, so they are
    # first-class fields here — never smuggled into the constraint hash, which
    # describes *what the dep is* (the resolver's fetch id).
    #
    # - name:         dependency name (e.g. "boost", "luaunit")
    # - integration:  symbol identifying the Integration type (:cmake, :luarocks, :brew, …)
    # - constraint:   version constraint hash (integration-specific, e.g. { "tag" => "v1.0" })
    # - post_install: callable or array of callables to run after the dep is fetched.
    #                 Each callable receives (dep, project_root). Not serialized to lockfile.
    DependencyDeclaration = Data.define(
      :name, :integration, :constraint, :group, :platform, :host, :env, :post_install,
    ) do
      def initialize(name:, integration:, constraint: {}, group: :app, platform: nil,
                     host: nil, env: nil, post_install: nil)
        super(name:, integration:, constraint:, group:, platform:,
              host: host&.to_sym, env: env&.to_s, post_install:)
      end
    end
  end
end

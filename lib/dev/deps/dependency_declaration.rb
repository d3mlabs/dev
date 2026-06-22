# frozen_string_literal: true

module Dev
  module Deps
    # A declared dependency before resolution.
    #
    # Represents what the user declares in the DSL — a name, integration type,
    # version constraint, and group. The Resolver consumes these and produces
    # fully resolved Dependency objects.
    #
    # - name:         dependency name (e.g. "boost", "luaunit")
    # - integration:  symbol identifying the Integration type (:cmake, :luarocks, :brew, …)
    # - constraint:   version constraint hash (integration-specific, e.g. { "tag" => "v1.0" })
    # - group:        symbol identifying the group (e.g. :app, :test, :build — user-defined)
    # - platform:     the platform of the declaring group (e.g. "LinuxServer"), or nil to let
    #                 the integration pick its default. Multi-arch integrations (ficsit) resolve
    #                 a dep for the union of the platforms of every group that declares it.
    # - post_install: callable or array of callables to run after the dep is fetched.
    #                 Each callable receives (dep, project_root). Not serialized to lockfile.
    DependencyDeclaration = Data.define(:name, :integration, :constraint, :group, :platform, :post_install) do
      def initialize(name:, integration:, constraint: {}, group: :app, platform: nil, post_install: nil)
        super(name:, integration:, constraint:, group:, platform:, post_install:)
      end
    end
  end
end

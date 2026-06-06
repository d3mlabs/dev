# frozen_string_literal: true

module Dev
  module Deps
    # A declared dependency before resolution.
    #
    # Represents what the user declares in the DSL — a name, integration type,
    # version constraint, and group. The Resolver consumes these and produces
    # fully resolved Dependency objects.
    #
    # - name:        dependency name (e.g. "boost", "luaunit")
    # - integration: symbol identifying the Integration type (:cmake, :luarocks, :brew, …)
    # - constraint:  version constraint hash (integration-specific, e.g. { "tag" => "v1.0" })
    # - group:       symbol identifying the group (e.g. :app, :test, :build — user-defined)
    DependencyDeclaration = Data.define(:name, :integration, :constraint, :group) do
      def initialize(name:, integration:, constraint: {}, group: :app)
        super(name:, integration:, constraint:, group:)
      end
    end
  end
end

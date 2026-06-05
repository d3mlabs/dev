# frozen_string_literal: true

require_relative "dependency"
require_relative "dependency_declaration"

module Dev
  module Deps
    # Resolves all dependency declarations into a flat list of Dependencies.
    #
    # Iterates declared deps, queries each Repository to fetch the dependency,
    # then walks transitive deps via Dependency#dependencies.
    # Registries that support dependency metadata (LuaRocks, CurseForge, Brew)
    # get full transitive resolution. Source-based repos (Git, URL) return [].
    class Resolver
      class UnknownIntegrationError < StandardError; end

      # @param repositories [Hash{Symbol => Repository}] integration type → repository
      def initialize(repositories:)
        @repositories = repositories
      end

      # Resolve all declarations into a flat Dependency list.
      #
      # Iterates declared deps, queries each Repository to fetch the pinned
      # Dependency, then walks transitive deps via Dependency#dependencies.
      #
      # @param declarations [Array<DependencyDeclaration>] declared dependencies to resolve
      # @return [Array<Dependency>]
      # @raise [UnknownIntegrationError] if no repository is registered for a declaration's integration type
      def resolve(declarations)
        resolved = {}
        queue = declarations.dup

        while (decl = queue.shift)
          next if resolved.key?(decl.name)

          repo = @repositories[decl.integration]
          raise UnknownIntegrationError, "no repository registered for #{decl.integration.inspect}" unless repo

          id = decl.constraint.merge(
            "name" => decl.name,
            "integration" => decl.integration.to_s,
            "group" => decl.group.to_s,
          )

          dependency = repo.fetch(id)
          resolved[decl.name] = dependency

          dependency.dependencies.each do |tdep|
            next if resolved.key?(tdep[:name])
            queue << DependencyDeclaration.new(
              name: tdep[:name],
              integration: decl.integration,
              constraint: tdep[:constraint].is_a?(Hash) ? tdep[:constraint] : {},
              group: decl.group,
            )
          end
        end

        resolved.values
      end
    end
  end
end

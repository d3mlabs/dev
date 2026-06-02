# frozen_string_literal: true

require_relative "dependency"

module Dev
  module Deps
    # Resolves all dependency constraints into a flat list of Dependencies.
    #
    # Iterates declared deps, queries each Repository to fetch the dependency,
    # then walks transitive deps via Dependency#dependencies.
    # Registries that support dependency metadata (LuaRocks, CurseForge, Brew)
    # get full transitive resolution. Source-based repos (Git, URL) return [].
    class Resolver
      # @param repositories [Hash{Symbol => Repository}] integration type → repository
      def initialize(repositories:)
        @repositories = repositories
      end

      # Resolve all deps → flat Dependency list.
      #
      # @param deps [Array<Hash>] each has :name, :integration, :constraint, :group
      # @return [Array<Dependency>]
      def resolve(deps)
        resolved = {}
        queue = deps.dup

        while (dep = queue.shift)
          name = dep[:name]
          next if resolved.key?(name)

          repo = @repositories[dep[:integration]]
          raise "No repository registered for #{dep[:integration].inspect}" unless repo

          id = dep[:constraint].merge(
            "name" => name,
            "integration" => dep[:integration].to_s,
            "group" => dep[:group].to_s,
          )

          dependency = repo.fetch(id)
          resolved[name] = dependency

          dependency.dependencies.each do |tdep|
            next if resolved.key?(tdep[:name])
            queue << {
              name: tdep[:name],
              integration: dep[:integration],
              constraint: tdep[:constraint].is_a?(Hash) ? tdep[:constraint] : {},
              group: dep[:group],
            }
          end
        end

        resolved.values
      end
    end
  end
end

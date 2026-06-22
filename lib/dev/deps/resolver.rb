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
        platforms_by_name = platforms_by_name(declarations)
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

          # A dep declared in several groups is resolved once, for the union of
          # those groups' platforms. nil entries mean "the integration's default
          # platform" and are passed through so a multi-arch repository can expand
          # them. We only attach "platforms" when at least one group pinned an
          # explicit platform, so single-platform deps keep their legacy fetch id.
          platforms = platforms_by_name[decl.name] || []
          id["platforms"] = platforms if platforms.any? { |p| !p.nil? }

          dependency = repo.fetch(id)
          dependency = dependency.with(post_install: decl.post_install) if decl.post_install
          resolved[decl.name] = dependency

          dependency.dependencies.each do |tdep|
            next if resolved.key?(tdep[:name])
            queue << DependencyDeclaration.new(
              name: tdep[:name],
              integration: decl.integration,
              constraint: normalize_constraint(tdep[:constraint]),
              group: decl.group,
            )
          end
        end

        resolved.values
      end

      private

      # Collect, per dependency name, the platforms of every group that declares
      # it (preserving nils, which mean "integration default"). This is how the
      # same dep declared in two groups gets resolved for the union of their
      # platforms without per-dep platform lists.
      #
      # @param declarations [Array<DependencyDeclaration>]
      # @return [Hash{String => Array<String, nil>}] name → de-duped platform list
      def platforms_by_name(declarations)
        result = Hash.new { |h, k| h[k] = [] }
        declarations.each { |decl| result[decl.name] << decl.platform }
        result.transform_values(&:uniq)
      end

      # Normalize a transitive dep constraint to a Hash.
      #
      # Transitive deps from Dependency#dependencies may express constraints as
      # a string (e.g. ">= 1.0") or a Hash. Strings are wrapped so they are not
      # silently dropped when merged into the fetch ID.
      #
      # @param constraint [Hash, String, nil] raw constraint from Dependency#dependencies
      # @return [Hash]
      def normalize_constraint(constraint)
        case constraint
        when Hash then constraint
        when String then { "version" => constraint }
        else {}
        end
      end
    end
  end
end

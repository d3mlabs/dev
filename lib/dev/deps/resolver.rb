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
        prepare_repositories(declarations)

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
          dependency = attach_install_scoping(dependency, decl)
          resolved[decl.name] = dependency

          # Transitive deps inherit the declaring dep's group, host, and env: a
          # dep only needed on one host/env can't need its transitive closure
          # anywhere else.
          dependency.dependencies.each do |tdep|
            next if resolved.key?(tdep[:name])
            queue << DependencyDeclaration.new(
              name: tdep[:name],
              integration: decl.integration,
              constraint: normalize_constraint(tdep[:constraint]),
              group: decl.group,
              host: decl.host,
              env: decl.env,
            )
          end
        end

        resolved.values
      end

      private

      # Stamp the declaration's install-scoping axes (host, env) onto the
      # resolved dependency's metadata so they serialize into the lockfile and
      # the installer can filter on them. Done here, uniformly, so no
      # repository has to know these axes exist — a repository resolves what a
      # dep IS; where it installs is resolver/installer plumbing.
      #
      # @param dependency [Dependency] freshly fetched
      # @param decl [DependencyDeclaration] the declaration it came from
      # @return [Dependency]
      def attach_install_scoping(dependency, decl)
        extra = {}
        extra["host"] = decl.host.to_s if decl.host
        extra["env"] = decl.env if decl.env
        return dependency if extra.empty?

        dependency.with(metadata: dependency.metadata.merge(extra))
      end

      # Give each repository a chance to batch-resolve all declarations of its
      # type before per-dependency fetches begin. Most repositories inherit the
      # no-op; bundler uses it to generate the Gemfile and run `bundle lock` once.
      #
      # @param declarations [Array<DependencyDeclaration>] all declarations
      # @return [void]
      def prepare_repositories(declarations)
        declarations.group_by(&:integration).each do |type, typed_declarations|
          @repositories[type]&.prepare(typed_declarations)
        end
      end

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

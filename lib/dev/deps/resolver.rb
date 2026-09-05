# typed: strict
# frozen_string_literal: true

require_relative "dependency"
require_relative "dependency_declaration"
require_relative "package"
require_relative "package_id"
require_relative "package_version"
require_relative "repository"
require_relative "version_scheme"

module Dev
  module Deps
    # Resolves all dependency declarations into a flat list of pinned
    # Dependencies.
    #
    # The choice layer of the deps pipeline: repositories report facts (which
    # versions exist — Repository#find), schemes evaluate predicates (does a
    # version satisfy a constraint — VersionScheme), and this class chooses:
    # for each declaration it filters the package's universe through the
    # integration's scheme, takes the highest satisfying version, mints the
    # pin, and walks that version's edges to resolve transitives. Whole-set
    # solves (bundle lock) happen before resolution, in the integration's
    # Locker — by the time find runs, a tool-locked universe is already
    # materialized. See docs/deps-architecture.md.
    class Resolver
      extend T::Sig

      # A declaration names an integration the registry doesn't wire.
      class UnknownIntegrationError < StandardError; end

      # The same dependency is declared twice with disagreeing constraints.
      class ConflictingDeclarationError < StandardError; end

      # No version in the package's universe satisfies the declaration —
      # constraint mismatch, missing requested platform, or empty universe.
      class NoSatisfyingVersionError < StandardError; end

      # @param repositories [Hash{Symbol => Repository}] integration type → repository
      # @param schemes [Hash{Symbol => VersionScheme}] integration type → constraint semantics
      sig do
        params(
          repositories: T::Hash[Symbol, Repository],
          schemes: T::Hash[Symbol, VersionScheme],
        ).void
      end
      def initialize(repositories:, schemes:)
        @repositories = repositories
        @schemes = schemes
      end

      # Resolve all declarations into a flat Dependency list.
      #
      # @param declarations [Array<DependencyDeclaration>] declared dependencies to resolve
      # @return [Array<Dependency>]
      # @raise [ConflictingDeclarationError] if one name is declared with disagreeing constraints
      # @raise [UnknownIntegrationError] if a declaration's integration has no repository or scheme
      # @raise [NoSatisfyingVersionError] if a declaration cannot be satisfied
      sig { params(declarations: T::Array[DependencyDeclaration]).returns(T::Array[Dependency]) }
      def resolve(declarations)
        reject_conflicts(declarations)

        platforms_by_name = platforms_by_name(declarations)
        resolved = T.let({}, T::Hash[String, Dependency])
        queue = declarations.dup

        while (decl = queue.shift)
          next if resolved.key?(decl.name)

          chosen = choose(decl, platforms_by_name[decl.name] || [])
          resolved[decl.name] = mint(chosen, decl)

          # Transitive deps inherit the declaring dep's group, host, and env: a
          # dep only needed on one host/env can't need its transitive closure
          # anywhere else.
          chosen.dependencies.each do |edge|
            next if resolved.key?(edge.name)

            queue << DependencyDeclaration.new(
              name: edge.name,
              integration: decl.integration,
              constraint: normalize_constraint(edge.constraint),
              group: decl.group,
              host: decl.host,
              env: decl.env,
            )
          end
        end

        resolved.values
      end

      private

      # Ask the declaration's repository for the package universe and pick the
      # highest version that satisfies the constraint (per the integration's
      # scheme) and publishes every explicitly requested platform.
      #
      # @param decl [DependencyDeclaration] the declaration to satisfy
      # @param platforms [Array<String, nil>] union of the declaring groups'
      #   platforms; nil entries mean "the integration's default"
      # @return [PackageVersion] the chosen version
      # @raise [UnknownIntegrationError] if repository or scheme is unwired
      # @raise [NoSatisfyingVersionError] if nothing in the universe qualifies
      sig do
        params(
          decl: DependencyDeclaration,
          platforms: T::Array[T.nilable(String)],
        ).returns(PackageVersion)
      end
      def choose(decl, platforms)
        repository = @repositories[decl.integration]
        raise UnknownIntegrationError, "no repository registered for #{decl.integration.inspect}" unless repository

        scheme = @schemes[decl.integration]
        raise UnknownIntegrationError, "no version scheme registered for #{decl.integration.inspect}" unless scheme

        # The constraint doubles as the repository's locator; platforms ride
        # along only when at least one group pinned one explicitly, so
        # single-platform deps keep their default-platform install facts.
        filter = decl.constraint.dup
        filter["platforms"] = platforms if platforms.any? { |p| !p.nil? }

        package = repository.find(package_id(decl), filter: filter)
        explicit = platforms.compact
        candidates = package.versions.select do |version|
          satisfies?(scheme, version, decl.constraint) && publishes_platforms?(version, explicit)
        end
        raise NoSatisfyingVersionError, no_satisfying_message(decl, package, explicit) if candidates.empty?

        # A universe can list one version string several times (e.g. per-arch
        # rows); selection is over distinct version strings, first fact wins.
        by_version = T.let({}, T::Hash[String, PackageVersion])
        candidates.each { |version| by_version[version.version] ||= version }
        by_version.fetch(T.must(scheme.sort(by_version.keys).last))
      end

      # Constraint satisfaction, treating versions the scheme cannot parse as
      # non-satisfying: a universe can contain versions that predate or ignore
      # the ecosystem's conventions, and they simply aren't candidates. A
      # malformed constraint, by contrast, propagates — that's the user's
      # declaration being wrong.
      #
      # @param scheme [VersionScheme] the integration's constraint semantics
      # @param version [PackageVersion] the candidate
      # @param constraint [Hash] the declaration constraint
      # @return [Boolean]
      sig do
        params(
          scheme: VersionScheme,
          version: PackageVersion,
          constraint: T::Hash[String, T.untyped],
        ).returns(T::Boolean)
      end
      def satisfies?(scheme, version, constraint)
        scheme.satisfies?(version.version, constraint)
      rescue VersionScheme::InvalidVersionError
        false
      end

      # Does the version publish every explicitly requested platform? Versions
      # that declare no platforms at all are platform-agnostic and always
      # qualify.
      #
      # @param version [PackageVersion] the candidate
      # @param explicit [Array<String>] explicitly requested platform names
      # @return [Boolean]
      sig { params(version: PackageVersion, explicit: T::Array[String]).returns(T::Boolean) }
      def publishes_platforms?(version, explicit)
        explicit.empty? || version.platforms.empty? || (explicit - version.platforms).empty?
      end

      # Mint the pin: the chosen version's facts become the Dependency, with
      # the declaration contributing name/integration/group, the post-install
      # hook, and the install-scoping axes. The version digest becomes the
      # pin's integrity hash uniformly; an empty version string (ecosystems
      # that expose no version, e.g. brew casks) becomes a nil pin version.
      #
      # @param chosen [PackageVersion] the version the resolver picked
      # @param decl [DependencyDeclaration] the declaration it satisfies
      # @return [Dependency]
      sig { params(chosen: PackageVersion, decl: DependencyDeclaration).returns(Dependency) }
      def mint(chosen, decl)
        dependency = Dependency.new(
          name: decl.name,
          integration: decl.integration,
          group: decl.group,
          version: chosen.version.empty? ? nil : chosen.version,
          hash: chosen.digest,
          metadata: chosen.metadata.dup,
        )
        dependency = dependency.with(post_install: decl.post_install) if decl.post_install
        attach_install_scoping(dependency, decl)
      end

      # The package's identity, from the declaration: for source-based deps
      # the constraint's "repo"/"url" is the source coordinate (which service
      # to ask), so it rides on the PackageId rather than the filter.
      #
      # @param decl [DependencyDeclaration]
      # @return [PackageId]
      sig { params(decl: DependencyDeclaration).returns(PackageId) }
      def package_id(decl)
        PackageId.new(
          integration: decl.integration,
          name: decl.name,
          source: decl.constraint["repo"] || decl.constraint["url"],
        )
      end

      # Reject sets where one name is declared with disagreeing constraints.
      # A dep declared in several groups resolves once, so agreement is the
      # precondition for that single resolution being right for everyone.
      # (Platform, group, host, and env may differ — they are axes, not
      # constraints.)
      #
      # @param declarations [Array<DependencyDeclaration>]
      # @return [void]
      # @raise [ConflictingDeclarationError]
      sig { params(declarations: T::Array[DependencyDeclaration]).void }
      def reject_conflicts(declarations)
        declarations.group_by(&:name).each do |name, decls|
          constraints = decls.map(&:constraint).uniq
          next if constraints.size <= 1

          raise ConflictingDeclarationError,
            "#{name} is declared with disagreeing constraints: #{constraints.map(&:inspect).join(" vs ")}"
        end
      end

      # Stamp the declaration's install-scoping axes (host, env) onto the
      # resolved dependency's metadata so they serialize into the lockfile and
      # the installer can filter on them. Done here, uniformly, so no
      # repository has to know these axes exist — a repository resolves what a
      # dep IS; where it installs is resolver/installer plumbing.
      #
      # @param dependency [Dependency] freshly minted
      # @param decl [DependencyDeclaration] the declaration it came from
      # @return [Dependency]
      sig { params(dependency: Dependency, decl: DependencyDeclaration).returns(Dependency) }
      def attach_install_scoping(dependency, decl)
        extra = {}
        extra["host"] = decl.host.to_s if decl.host
        extra["env"] = decl.env if decl.env
        return dependency if extra.empty?

        dependency.with(metadata: dependency.metadata.merge(extra))
      end

      # Collect, per dependency name, the platforms of every group that declares
      # it (preserving nils, which mean "integration default"). This is how the
      # same dep declared in two groups gets resolved for the union of their
      # platforms without per-dep platform lists.
      #
      # @param declarations [Array<DependencyDeclaration>]
      # @return [Hash{String => Array<String, nil>}] name → de-duped platform list
      sig do
        params(
          declarations: T::Array[DependencyDeclaration],
        ).returns(T::Hash[String, T::Array[T.nilable(String)]])
      end
      def platforms_by_name(declarations)
        result = Hash.new { |h, k| h[k] = [] }
        declarations.each { |decl| result[decl.name] << decl.platform }
        result.transform_values(&:uniq)
      end

      # Normalize a transitive edge constraint to a declaration constraint
      # hash. Edges may express constraints as a bare string (ficsit's
      # "^3.12.0"), which maps to the ecosystem's "version" key.
      #
      # @param constraint [Hash, String, nil] raw constraint from a DependencyEdge
      # @return [Hash]
      sig do
        params(
          constraint: T.nilable(T.any(T::Hash[String, T.untyped], String)),
        ).returns(T::Hash[String, T.untyped])
      end
      def normalize_constraint(constraint)
        case constraint
        when Hash then constraint
        when String then { "version" => constraint }
        else {}
        end
      end

      # A NoSatisfyingVersionError message that says why: what was asked,
      # what the universe held.
      #
      # @param decl [DependencyDeclaration]
      # @param package [Package]
      # @param explicit [Array<String>] explicitly requested platforms
      # @return [String]
      sig do
        params(
          decl: DependencyDeclaration,
          package: Package,
          explicit: T::Array[String],
        ).returns(String)
      end
      def no_satisfying_message(decl, package, explicit)
        wanted = decl.constraint.empty? ? "any version" : decl.constraint.inspect
        wanted += " on #{explicit.join(", ")}" unless explicit.empty?
        "no version of #{decl.name} satisfies #{wanted} " \
          "(universe: #{package.versions.size} version(s))"
      end
    end
  end
end

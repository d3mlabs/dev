# typed: strict
# frozen_string_literal: true

require_relative "declaration"
require_relative "declarations"
require_relative "dependency"
require_relative "package"
require_relative "scoped_declaration"
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
    # materialized.
    #
    # Edges come from two places and ride one walk. A chosen version's
    # Resolved declarations claim is the universe's edge (a ficsit mod needs
    # a mod). The *needs table* is the integration's edge: an integration's
    # own dependencies.rb exports the tooling it shells to (xcode needs
    # `brew "xcodes"`), and every declaration of that integration pulls those
    # exports into the project's lock as ordinary pins in their channel, in
    # the using declaration's scope, with provenance (`needed_by`) the
    # installer orders by. See docs/deps-architecture.md.
    class Resolver
      extend T::Sig

      # A declaration names an integration the registry doesn't wire.
      class UnknownIntegrationError < StandardError; end

      # The same dependency is declared twice with disagreeing constraints.
      class ConflictingDeclarationError < StandardError; end

      # No version in the package's universe satisfies the declaration —
      # constraint mismatch, missing requested platform, or empty universe.
      class NoSatisfyingVersionError < StandardError; end

      # What two declarations of one package must agree on to resolve once.
      Ask = T.type_alias { T::Hash[Symbol, T.untyped] }

      # @param repositories [Hash{Symbol => Repository}] integration type → repository
      # @param schemes [Hash{Symbol => VersionScheme}] integration type → constraint semantics
      # @param needs [Hash{Symbol => Array<ScopedDeclaration>}] integration
      #   type → the declarations its own manifest exports
      #   (IntegrationNeeds#table); absent means the integration needs no
      #   tooling of its own
      sig do
        params(
          repositories: T::Hash[Symbol, Repository],
          schemes: T::Hash[Symbol, VersionScheme],
          needs: T::Hash[Symbol, T::Array[ScopedDeclaration]],
        ).void
      end
      def initialize(repositories:, schemes:, needs: {})
        @repositories = repositories
        @schemes = schemes
        @needs = needs
      end

      # Resolve all declarations into a flat Dependency list.
      #
      # The resolved set is keyed by PackageId, so the same name under two
      # integrations is two packages — each resolves against its own
      # integration's universe. Transitive declarations resolve under the
      # integration their reporting Repository stamped on them (today always
      # its own).
      #
      # The needs of a declaration's integration ride the same walk, with the
      # integration as parent: each export of its manifest is queued under
      # the using declaration's scope (narrowed by the need's own host/env,
      # if it states any), and the pin it resolves to records the integration
      # under `needed_by`. A project declaring the same tool itself merges
      # with the need when the asks agree and is a ConflictingDeclarationError
      # when they do not — the Gemfile convention: the library declares, the
      # project locks, and two asks for one package must be one ask.
      #
      # @param declarations [Array<ScopedDeclaration>] declared dependencies to resolve
      # @return [Array<Dependency>]
      # @raise [ConflictingDeclarationError] if one package is declared with
      #   disagreeing asks, by the project or by an integration's manifest
      # @raise [UnknownIntegrationError] if a declaration's integration has no repository or scheme
      # @raise [NoSatisfyingVersionError] if a declaration cannot be satisfied
      sig { params(declarations: T::Array[ScopedDeclaration]).returns(T::Array[Dependency]) }
      def resolve(declarations)
        asks = reject_conflicts(declarations)

        platforms = declared_platforms(declarations)
        resolved = T.let({}, T::Hash[PackageId, Dependency])
        needed_by = T.let({}, T::Hash[PackageId, T::Array[Symbol]])
        queue = declarations.dup

        while (decl = queue.shift)
          id = package_id(decl)
          next if resolved.key?(id)

          declared = platforms[[decl.integration, decl.name]] || []
          chosen = decl.revision ? address(decl) : choose(decl, declared)
          resolved[id] = mint(chosen, decl, declared)

          queue.concat(universe_edges(chosen, decl))
          queue.concat(needs_under(decl, asks, needed_by))
        end

        stamp_provenance(resolved, needed_by)
      end

      private

      # The chosen version's declared deps as requirements under the parent's
      # context. Transitive deps inherit the declaring dep's Scope wholesale:
      # a dep only needed in one group/host/env can't need its transitive
      # closure anywhere else. Each Declaration arrives finished from the
      # Repository (integration stamped, constraint normalized); only the
      # context is stamped here, because context is a property of the path,
      # not of the fact.
      #
      # @param chosen [PackageVersion] the version just pinned
      # @param decl [ScopedDeclaration] the declaration it satisfies
      # @return [Array<ScopedDeclaration>] the edges to queue
      sig { params(chosen: PackageVersion, decl: ScopedDeclaration).returns(T::Array[ScopedDeclaration]) }
      def universe_edges(chosen, decl)
        case (claim = chosen.declarations)
        when Declarations::Resolved
          claim.declarations.map { |edge| ScopedDeclaration.new(declaration: edge, scope: decl.scope) }
        when Declarations::ToolOwned
          # The ecosystem's tool owns the closure; there is nothing to walk.
          []
        else
          T.absurd(claim)
        end
      end

      # The needs of the declaration's integration, as requirements under
      # the declaration's context. A need whose own host/env is disjoint from
      # the parent's applies nowhere beneath it and is skipped (a darwin-only
      # tool under a linux-only use); the rest are checked against every ask
      # seen so far and recorded as needed by this integration — recorded
      # even when the package is already resolved, so the provenance is
      # complete whichever path reached it first.
      #
      # @param decl [ScopedDeclaration] the using declaration (the parent)
      # @param asks [Hash{Array(Symbol, String) => Ask}] every ask seen so far, by package; grown here
      # @param needed_by [Hash{PackageId => Array<Symbol>}] provenance under construction; grown here
      # @return [Array<ScopedDeclaration>] the needs to queue
      # @raise [ConflictingDeclarationError] if a need disagrees with an earlier ask
      sig do
        params(
          decl: ScopedDeclaration,
          asks: T::Hash[[Symbol, String], Ask],
          needed_by: T::Hash[PackageId, T::Array[Symbol]],
        ).returns(T::Array[ScopedDeclaration])
      end
      def needs_under(decl, asks, needed_by)
        @needs.fetch(decl.integration, []).filter_map do |need|
          scope = need.scope.under(decl.scope)
          next if scope.nil?

          reject_disagreement(need, asks, needed_by_integration: decl.integration)
          scoped = need.with_scope(scope)
          (needed_by[package_id(scoped)] ||= []) << decl.integration
          scoped
        end
      end

      # Write each pin's provenance: the integrations whose manifests need
      # it, sorted, so the lock reads the same whichever order the walk ran.
      #
      # @param resolved [Hash{PackageId => Dependency}] every minted pin
      # @param needed_by [Hash{PackageId => Array<Symbol>}] provenance per package
      # @return [Array<Dependency>] the pins, provenance stamped
      sig do
        params(
          resolved: T::Hash[PackageId, Dependency],
          needed_by: T::Hash[PackageId, T::Array[Symbol]],
        ).returns(T::Array[Dependency])
      end
      def stamp_provenance(resolved, needed_by)
        resolved.map do |id, pin|
          next pin unless needed_by.key?(id)

          parents = needed_by.fetch(id).map(&:to_s).uniq.sort
          pin.with(metadata: pin.metadata.merge(Dependency::NEEDED_BY => parents))
        end
      end

      # Lift an addressed ask. The author forewent resolution: no universe is
      # queried, no scheme runs — the repository lifts the revision into a
      # version (Repository#at is pure) and the pin is minted from it
      # directly. A repository with no continuous space refuses, and that
      # refusal propagates: an address into a space that doesn't exist is the
      # declaration being wrong.
      #
      # @param decl [ScopedDeclaration] a revision-pinned declaration
      # @return [PackageVersion] the lifted version
      # @raise [UnknownIntegrationError] if the integration has no repository
      # @raise [Repository::NoAddressableSpaceError] if the integration's
      #   universe has no continuous space
      sig { params(decl: ScopedDeclaration).returns(PackageVersion) }
      def address(decl)
        repository = @repositories[decl.integration]
        raise UnknownIntegrationError, "no repository registered for #{decl.integration.inspect}" unless repository

        repository.at(package_id(decl), T.must(decl.revision))
      end

      # Ask the declaration's repository for the package universe and pick the
      # highest version that satisfies the constraint (per the integration's
      # scheme) and publishes every explicitly requested platform.
      #
      # @param decl [ScopedDeclaration] the declaration to satisfy
      # @param platforms [Array<String, nil>] union of the declaring groups'
      #   platforms; nil entries mean "the integration's default"
      # @return [PackageVersion] the chosen version
      # @raise [UnknownIntegrationError] if repository or scheme is unwired
      # @raise [NoSatisfyingVersionError] if nothing in the universe qualifies
      sig do
        params(
          decl: ScopedDeclaration,
          platforms: T::Array[T.nilable(String)],
        ).returns(PackageVersion)
      end
      def choose(decl, platforms)
        repository = @repositories[decl.integration]
        raise UnknownIntegrationError, "no repository registered for #{decl.integration.inspect}" unless repository

        # Scheme-less integrations (url) have no constraint grammar at all:
        # an empty ask takes the universe as reported, a non-empty one is the
        # declaration being wrong.
        scheme = @schemes[decl.integration]
        if scheme.nil? && !decl.constraint.empty?
          raise UnknownIntegrationError,
            "#{decl.integration.inspect} has no version scheme — it cannot evaluate " \
              "constraint #{decl.constraint.inspect}"
        end

        package = repository.find(package_id(decl))
        explicit = platforms.compact
        candidates = package.versions.select do |version|
          (scheme.nil? || satisfies?(scheme, version, decl.constraint)) &&
            publishes_platforms?(version, explicit)
        end
        raise NoSatisfyingVersionError, no_satisfying_message(decl, package, explicit) if candidates.empty?

        # A universe can list one version string several times (e.g. per-arch
        # rows); selection is over distinct version strings, first fact wins.
        by_version = T.let({}, T::Hash[String, PackageVersion])
        candidates.each { |version| by_version[version.version] ||= version }
        by_version.fetch(T.must(sorted_versions(scheme, by_version.keys).last))
      end

      # Order distinct version strings ascending: the scheme's total order,
      # or the universe's reported order when no scheme exists.
      #
      # @param scheme [VersionScheme, nil] the integration's semantics, if any
      # @param versions [Array<String>] distinct version strings
      # @return [Array<String>]
      sig { params(scheme: T.nilable(VersionScheme), versions: T::Array[String]).returns(T::Array[String]) }
      def sorted_versions(scheme, versions)
        scheme ? scheme.sort(versions) : versions
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
        scheme.satisfies?(version, constraint)
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

      # Mint the pin: the chosen version's facts become the Dependency, the
      # declaration contributes name/integration/group, its materialization
      # (install instructions the repository never saw), the post-install
      # hook, and the install-scoping axes. The version digest becomes the
      # pin's integrity hash uniformly; an empty version string (ecosystems
      # that expose no version — brew casks, url artifacts) becomes a nil pin
      # version, unless the author named a display label (a url tag:), which
      # is promoted out of the materialization into the version slot.
      # Versions carrying per-platform artifacts get them projected into
      # install facts against the declared platforms.
      #
      # @param chosen [PackageVersion] the version the resolver picked
      # @param decl [ScopedDeclaration] the declaration it satisfies
      # @param platforms [Array<String, nil>] union of the declaring groups' platforms
      # @return [Dependency]
      sig do
        params(
          chosen: PackageVersion,
          decl: ScopedDeclaration,
          platforms: T::Array[T.nilable(String)],
        ).returns(Dependency)
      end
      def mint(chosen, decl, platforms)
        metadata = chosen.metadata.merge(decl.materialization)
        pin_version = chosen.version.empty? ? metadata.delete("version_label") : chosen.version
        hash = chosen.digest
        if chosen.artifacts.any? && (platforms.any? { |p| !p.nil? } || metadata.key?("target") || chosen.platforms.any?)
          hash = project_artifacts(metadata, chosen, platforms)
        end

        dependency = Dependency.new(
          name: decl.name,
          integration: decl.integration,
          group: decl.scope.group,
          version: pin_version,
          hash: hash,
          metadata: metadata,
        )
        dependency = dependency.with(post_install: decl.post_install) if decl.post_install
        attach_install_scoping(dependency, decl)
      end

      # Project the chosen version's per-platform artifacts (universe facts)
      # into the pin's install facts. Three shapes:
      #
      # - explicitly declared platforms: a metadata["platforms"] block
      #   covering the declared targets the version publishes (nil entries
      #   fall back to the materialization's "target");
      # - nothing declared, but the version publishes named platforms: the
      #   block covers every one of them — the lock describes the universe,
      #   not the machine that wrote it, so a brew formula's pin is the same
      #   whether a Mac or a Linux box ran `dev deps update`;
      # - otherwise the single-target shape: the materialization's "target"
      #   (else the version's one default artifact) resolved to its digest
      #   as the pin's hash.
      #
      # Lives here, not in a Repository: which targets a pin describes is a
      # property of the declarations meeting the version, and a repository
      # never sees declarations.
      #
      # @param metadata [Hash] the pin metadata under construction (mutated)
      # @param chosen [PackageVersion] the chosen version
      # @param platforms [Array<String, nil>] declared platforms; nil entries
      #   fall back to the materialization's "target"
      # @return [String, nil] the pin's integrity hash
      sig do
        params(
          metadata: T::Hash[String, T.untyped],
          chosen: PackageVersion,
          platforms: T::Array[T.nilable(String)],
        ).returns(T.nilable(String))
      end
      def project_artifacts(metadata, chosen, platforms)
        default_target = metadata["target"]
        explicit = platforms.any? { |p| !p.nil? }

        if explicit || (default_target.nil? && chosen.platforms.any?)
          names = explicit ? platforms.map { |p| p.nil? ? default_target : p }.compact.uniq : chosen.platforms
          metadata["platforms"] = names.each_with_object({}) do |name, acc|
            artifact = chosen.artifacts[name]
            acc[name] = { "hash" => artifact.digest, "link" => artifact.uri } if artifact
          end
          # The block replaces the single-target shape; no one target is THE pin.
          metadata.delete("target")
          nil
        else
          artifact = chosen.artifacts[default_target] || chosen.artifacts.values.first
          artifact&.digest
        end
      end

      # The package's identity, from the declaration: the atom's source field
      # is the source coordinate (which universe to ask), riding on the
      # PackageId.
      #
      # @param decl [ScopedDeclaration]
      # @return [PackageId]
      sig { params(decl: ScopedDeclaration).returns(PackageId) }
      def package_id(decl)
        PackageId.new(
          integration: decl.integration,
          name: decl.name,
          source: decl.source,
        )
      end

      # Reject sets where one package is declared with disagreeing asks —
      # constraint, source, revision, or materialization. A dep declared in several
      # groups resolves once, so agreement is the precondition for that single
      # resolution being right for everyone; disagreeing asset globs would
      # otherwise let one row's materialization win silently. Grouping is per
      # (integration, name): the same name under two integrations is two
      # packages, free to carry different asks. (Platform, group, host, and
      # env may differ — they are axes, not asks.)
      #
      # @param declarations [Array<ScopedDeclaration>]
      # @return [Hash{Array(Symbol, String) => Ask}] the one ask per package,
      #   for the walk to hold later asks (an integration's needs) to
      # @raise [ConflictingDeclarationError]
      sig { params(declarations: T::Array[ScopedDeclaration]).returns(T::Hash[[Symbol, String], Ask]) }
      def reject_conflicts(declarations)
        declarations.group_by { |d| [d.integration, d.name] }.to_h do |(integration, name), decls|
          asks = decls.map { |d| ask(d) }.uniq
          if asks.size > 1
            raise ConflictingDeclarationError,
              "#{integration}/#{name} is declared with disagreeing asks: " \
                "#{asks.map(&:inspect).join(" vs ")}"
          end

          [[integration, name], T.must(asks.first)]
        end
      end

      # Hold a need to the ask already made for its package, if any: a
      # project that declares the tool an integration needs merges with the
      # need when the asks agree and conflicts when they do not. A need for a
      # package nobody asked for yet becomes the ask later needs are held to.
      #
      # @param need [ScopedDeclaration] the need an integration's manifest exports
      # @param asks [Hash{Array(Symbol, String) => Ask}] every ask seen so far; grown here
      # @param needed_by_integration [Symbol] the integration whose manifest exports the need
      # @return [void]
      # @raise [ConflictingDeclarationError] if the need disagrees with the earlier ask
      sig do
        params(
          need: ScopedDeclaration,
          asks: T::Hash[[Symbol, String], Ask],
          needed_by_integration: Symbol,
        ).void
      end
      def reject_disagreement(need, asks, needed_by_integration:)
        key = [need.integration, need.name]
        earlier = asks[key]
        if earlier && earlier != ask(need)
          raise ConflictingDeclarationError,
            "#{need.integration}/#{need.name} is declared with disagreeing asks: #{earlier.inspect} " \
              "vs #{ask(need).inspect} (needed by #{needed_by_integration})"
        end

        asks[key] = ask(need)
      end

      # What a declaration asks for — everything two declarations of one
      # package must agree on to resolve once.
      #
      # @param decl [ScopedDeclaration]
      # @return [Ask]
      sig { params(decl: ScopedDeclaration).returns(Ask) }
      def ask(decl)
        { constraint: decl.constraint, source: decl.source, revision: decl.revision, materialization: decl.materialization }
      end

      # Stamp the declaration's install-scoping axes (host, env) onto the
      # resolved dependency's metadata so they serialize into the lockfile and
      # the installer can filter on them. Done here, uniformly, so no
      # repository has to know these axes exist — a repository resolves what a
      # dep IS; where it installs is resolver/installer plumbing.
      #
      # @param dependency [Dependency] freshly minted
      # @param decl [ScopedDeclaration] the declaration it came from
      # @return [Dependency]
      sig { params(dependency: Dependency, decl: ScopedDeclaration).returns(Dependency) }
      def attach_install_scoping(dependency, decl)
        extra = decl.scope.to_metadata
        return dependency if extra.empty?

        dependency.with(metadata: dependency.metadata.merge(extra))
      end

      # Collect, per package (integration + name), the platforms of every group
      # that declares it (preserving nils, which mean "integration default").
      # This is how the same dep declared in two groups gets resolved for the
      # union of their platforms without per-dep platform lists — scoped per
      # integration so one ecosystem's platform pins never leak into another's.
      #
      # @param declarations [Array<ScopedDeclaration>]
      # @return [Hash{Array(Symbol, String) => Array<String, nil>}]
      #   (integration, name) → de-duped platform list
      sig do
        params(
          declarations: T::Array[ScopedDeclaration],
        ).returns(T::Hash[[Symbol, String], T::Array[T.nilable(String)]])
      end
      def declared_platforms(declarations)
        result = Hash.new { |h, k| h[k] = [] }
        declarations.each { |decl| result[[decl.integration, decl.name]] << decl.platform }
        result.transform_values(&:uniq)
      end

      # A NoSatisfyingVersionError message that says why: what was asked,
      # what the universe held.
      #
      # @param decl [ScopedDeclaration]
      # @param package [Package]
      # @param explicit [Array<String>] explicitly requested platforms
      # @return [String]
      sig do
        params(
          decl: ScopedDeclaration,
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

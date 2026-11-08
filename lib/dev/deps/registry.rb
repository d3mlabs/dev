# typed: strict
# frozen_string_literal: true

require_relative "artifact_store"
require_relative "tap"
require_relative "brew_repository"
require_relative "brew_integration"
require_relative "brew_publisher"
require "dev/brew_env"
require_relative "git_repository"
require_relative "cmake_integration"
require_relative "luarocks_repository"
require_relative "luarocks_integration"
require_relative "ficsit_repository"
require_relative "ficsit_integration"
require_relative "gh_repository"
require_relative "gh_integration"
require_relative "steam_repository"
require_relative "steam_integration"
require_relative "bundler_locker"
require_relative "bundler_repository"
require_relative "bundler_integration"
require_relative "xcode_repository"
require_relative "xcode_integration"
require_relative "wwise_repository"
require_relative "wwise_integration"
require_relative "pip_repository"
require_relative "pip_integration"
require_relative "url_repository"
require_relative "oci_repository"
require_relative "ghcr_publisher"
require_relative "rubygems_publisher"
require_relative "brew_cask_repository"
require_relative "brew_scheme"
require_relative "exact_scheme"
require_relative "gem_scheme"
require_relative "git_scheme"
require_relative "locker"
require_relative "pep440_scheme"
require_relative "rock_scheme"
require_relative "semver_scheme"
require_relative "steam_scheme"
require_relative "version_scheme"
require "dev/lifecycle/publisher"

module Dev
  module Deps
    # The single source of truth for how each dependency type is wired.
    #
    # Integration wiring used to live in two hand-maintained hashes in the runner
    # — one for resolution (repositories) and one for host install (integrations)
    # — and nothing kept them in sync with the classes that exist. That let a
    # whole integration (LuaRocks) ship resolved-but-never-installed. This table
    # is now the one place a type is declared; the runner derives both hashes from
    # it, and registry_consistency_test.rb fails CI if a repository/integration
    # class or DSL verb is left unwired.
    #
    # Each Entry says which Repository resolves the type, which Integration (if
    # any) installs it, which Publisher (if any) is its write side — the
    # `deploy` channel a project pinning the type gets (dev#422) — and which
    # extra constructor arguments each side needs (drawn from a context the
    # runner assembles). There is one integration set, for whichever build
    # host runs `dev deps install`: a build container is a host with its own
    # data root (ADR-0008), so nothing here says where a type installs — the
    # lock's `host:` filter does that per platform.
    module Registry
      # An Entry names a channel but has no publisher to contribute it.
      # Beside Entry rather than inside it: a class body in Data.define's
      # block is lexically the module's.
      class ChannelWithoutPublisherError < ArgumentError; end

      # @param symbol [Symbol] the DSL/declaration integration symbol (e.g. :brew)
      # @param repository [Class] Repository subclass that reports this type's universes
      # @param repository_needs [Array<Symbol>] extra kwargs the repository takes
      # @param scheme [Class, nil] VersionScheme subclass carrying this type's
      #   constraint semantics — every type must answer "how do constraints
      #   work", and nil is an answer: a purely addressable type (xcode) whose
      #   declarations carry a revision, never a constraint, has no scheme to
      #   run
      # @param scheme_args [Hash{Symbol => Object}] constructor kwargs for the
      #   scheme (e.g. ExactScheme's key:)
      # @param locker [Class, nil] Locker subclass for types whose ecosystem tool
      #   owns the whole-set solve (bundler), or nil
      # @param locker_needs [Array<Symbol>] extra kwargs the locker takes
      # @param integration [Class, nil] Integration subclass that installs this
      #   type, or nil for resolve-only / container-only types
      # @param integration_needs [Array<Symbol>] extra kwargs the integration takes
      #   (beyond the always-passed repository: and store:)
      # @param install_alias [Symbol, nil] another entry's symbol whose
      #   integration INSTANCE installs this type's deps too (e.g. :url deps
      #   install through :cmake's pipeline). Sharing the instance matters:
      #   integrations that generate batch artifacts (deps.cmake) must see
      #   both types' deps in one install_all call, and the Installer groups
      #   dispatch by instance. Mutually exclusive with integration.
      # @param publisher [Class, nil] the integration's **write side**
      #   (dev#192 K5, dev#422): a class implementing Lifecycle::Publisher
      #   that ships artifacts to the destination the read side resolves
      #   from — a built-in points it at its repository class when both
      #   share one client and auth (steamcmd, `gh`, the tap clone). A
      #   project whose lock pins a dependency of this type gets a `deploy`
      #   channel of this entry's name with no dev.yml line. nil for a type
      #   that is a source only.
      # @param publisher_needs [Array<Symbol>] extra kwargs the publisher takes
      # @param channel [String, nil] the name of the `deploy` channel the
      #   publisher contributes, when the **destination** is not called as
      #   the dependency type is: gems (`bundler`) ship to `rubygems`, an
      #   `image` is pushed to `ghcr`. nil names the channel after the
      #   entry (`steam`, `brew`), the common case where the integration
      #   and the store share a name. Meaningless without a publisher.
      Entry = Data.define(
        :symbol, :repository, :repository_needs, :scheme, :scheme_args, :locker, :locker_needs,
        :integration, :integration_needs, :install_alias, :publisher, :publisher_needs, :channel,
      ) do
        extend T::Sig

        # Sorbet's Data.define rewriter can't attach sigs to the generated
        # member readers (sorbet/sorbet#7272), so strict mode needs explicit
        # typed readers. Data#to_h reads members at the C level (it does not
        # call these readers), so the delegation is safe and non-recursive.
        sig { returns(Symbol) }
        def symbol = to_h.fetch(:symbol)

        sig { returns(T.class_of(Repository)) }
        def repository = to_h.fetch(:repository)

        sig { returns(T::Array[Symbol]) }
        def repository_needs = to_h.fetch(:repository_needs)

        sig { returns(T.nilable(T.class_of(VersionScheme))) }
        def scheme = to_h.fetch(:scheme)

        sig { returns(T::Hash[Symbol, T.untyped]) }
        def scheme_args = to_h.fetch(:scheme_args)

        sig { returns(T.nilable(T.class_of(Locker))) }
        def locker = to_h.fetch(:locker)

        sig { returns(T::Array[Symbol]) }
        def locker_needs = to_h.fetch(:locker_needs)

        sig { returns(T.nilable(T.class_of(Integration))) }
        def integration = to_h.fetch(:integration)

        sig { returns(T::Array[Symbol]) }
        def integration_needs = to_h.fetch(:integration_needs)

        sig { returns(T.nilable(Symbol)) }
        def install_alias = to_h.fetch(:install_alias)

        sig { returns(T.nilable(T::Class[Lifecycle::Publisher])) }
        def publisher = to_h.fetch(:publisher)

        sig { returns(T::Array[Symbol]) }
        def publisher_needs = to_h.fetch(:publisher_needs)

        sig { returns(T.nilable(String)) }
        def channel = to_h.fetch(:channel)

        sig do
          params(
            symbol: Symbol,
            repository: T.class_of(Repository),
            scheme: T.nilable(T.class_of(VersionScheme)),
            integration: T.nilable(T.class_of(Integration)),
            repository_needs: T::Array[Symbol],
            scheme_args: T::Hash[Symbol, T.untyped],
            locker: T.nilable(T.class_of(Locker)),
            locker_needs: T::Array[Symbol],
            integration_needs: T::Array[Symbol],
            install_alias: T.nilable(Symbol),
            publisher: T.nilable(T::Class[Lifecycle::Publisher]),
            publisher_needs: T::Array[Symbol],
            channel: T.nilable(String),
          ).void
        end
        def initialize(symbol:, repository:, scheme:, integration:,
                       repository_needs: [], scheme_args: {}, locker: nil, locker_needs: [],
                       integration_needs: [], install_alias: nil, publisher: nil, publisher_needs: [], channel: nil)
          super
          return if channel.nil? || publisher

          raise ChannelWithoutPublisherError, "entry #{symbol} names channel #{channel.inspect} but has no publisher to contribute it"
        end

        # @return [Boolean] whether this type installs on a build host (an
        #   aliased type installs through its target's instance instead)
        sig { returns(T::Boolean) }
        def host?
          !integration.nil?
        end

        # @return [Boolean] whether this type has a write side: a project
        #   pinning it gets a `deploy` channel of this entry's name
        sig { returns(T::Boolean) }
        def publishes?
          !publisher.nil?
        end

        # The `deploy` channel this entry contributes, when it publishes:
        # the destination's name — the entry's own when the integration and
        # the store share it (`deploy steam` is the `steam` integration's
        # write side), the `channel:` override when they do not (`deploy
        # rubygems` is where the `bundler` type's gems go).
        #
        # @return [String]
        sig { returns(String) }
        def channel_name = channel || symbol.to_s
      end

      INTEGRATIONS = T.let(
        [
          # Gems come from rubygems.org, so a project pinning gems can push
          # one there (dev#428): the write side is the `rubygems` channel,
          # named for the store rather than for bundler, the tool.
          Entry.new(
            symbol: :bundler,
            repository: BundlerRepository,
            repository_needs: %i[project_root],
            scheme: GemScheme,
            locker: BundlerLocker,
            locker_needs: %i[project_root ruby_version],
            integration: BundlerIntegration,
            integration_needs: %i[project_root],
            publisher: RubygemsPublisher,
            publisher_needs: %i[project_root],
            channel: "rubygems",
          ),
          # The write side (dev#429): a project pinning a formula from a tap
          # gets `deploy brew`, which points the tap's formula of each
          # target's name at that target's release asset.
          Entry.new(
            symbol: :brew,
            repository: BrewRepository,
            scheme: BrewScheme,
            integration: BrewIntegration,
            integration_needs: %i[taps project_dir project_name pin_taps brew_env],
            publisher: BrewPublisher,
            publisher_needs: %i[project_root taps],
          ),
          # Casks are declared with the brew DSL verb (cask: true) but are a
          # separate universe: Homebrew publishes no versions or bottle
          # digests for casks, so BrewRepository's formula facts don't apply.
          Entry.new(
            symbol: :cask,
            repository: BrewCaskRepository,
            scheme: BrewScheme,
            integration: BrewIntegration,
          ),
          # The project's interpreters are brew formulae with their own
          # constraint semantics, installed through brew's instance (the
          # same install_all call, so one activation covers every keg):
          # ruby ranges over the d3mlabs tap's immutable ruby@X.Y.Z family
          # with rubygems requirements; python selects core's python@minor
          # by suffix, as any versioned formula. Their own symbols keep the
          # lock legible (`ruby:`/`python:` sections) and let the install
          # step that activates an interpreter key on the pin, not its name.
          Entry.new(
            symbol: :ruby,
            repository: BrewRepository,
            scheme: GemScheme,
            integration: nil,
            install_alias: :brew,
          ),
          Entry.new(
            symbol: :python,
            repository: BrewRepository,
            scheme: BrewScheme,
            integration: nil,
            install_alias: :brew,
          ),
          Entry.new(
            symbol: :cmake,
            repository: GitRepository,
            scheme: GitScheme,
            integration: CmakeIntegration,
            integration_needs: %i[project_root],
          ),
          # url deps are declared with the cmake DSL verb (url:) but are a
          # separate universe: the URL is the entire address and the artifact
          # behind it is the one version, downloaded and TOFU-hashed by find.
          # Scheme-less — a url declaration carries no constraint (the tag:
          # label is naming, not selection) — and installed through cmake's
          # integration instance so a mixed project generates one deps.cmake.
          Entry.new(
            symbol: :url,
            repository: UrlRepository,
            scheme: nil,
            integration: nil,
            install_alias: :cmake,
          ),
          Entry.new(
            symbol: :luarocks,
            repository: LuaRocksRepository,
            scheme: RockScheme,
            integration: LuaRocksIntegration,
            integration_needs: %i[project_root],
          ),
          Entry.new(
            symbol: :ficsit,
            repository: FicsitRepository,
            scheme: SemverScheme,
            integration: FicsitIntegration,
          ),
          Entry.new(
            symbol: :gh,
            repository: GhRepository,
            scheme: ExactScheme,
            scheme_args: { key: "tag" },
            integration: GhIntegration,
            integration_needs: %i[project_root],
          ),
          Entry.new(
            symbol: :steam,
            repository: SteamRepository,
            scheme: SteamScheme,
            integration: SteamIntegration,
          ),
          Entry.new(
            symbol: :xcode,
            repository: XcodeRepository,
            # Purely addressable: the DSL mints the exact version as the
            # declaration's revision, so no constraint ever needs evaluating.
            scheme: nil,
            integration: XcodeIntegration,
            integration_needs: %i[project_root],
          ),
          Entry.new(
            symbol: :wwise,
            repository: WwiseRepository,
            # Purely addressable, like xcode: Audiokinetic's version list is
            # behind a login, so the DSL mints the SDK version as the revision.
            scheme: nil,
            integration: WwiseIntegration,
          ),
          Entry.new(
            symbol: :pip,
            repository: PipRepository,
            scheme: Pep440Scheme,
            integration: PipIntegration,
            integration_needs: %i[project_root],
          ),
          # An environment image's floor (dev#277): the tag is the whole
          # ask (url model, so no scheme), resolved to the digest the
          # registry serves. Nothing installs it — an image is not a store
          # tree (ADR-0009) — the container layer reads the pin
          # (Dev::EnvironmentImage) and builds or pulls the image from it.
          # The write side (dev#428) is the registry the floor is pulled
          # from: a project pinning an image can push one to GHCR, the
          # `ghcr` channel.
          Entry.new(
            symbol: :image,
            repository: OciRepository,
            scheme: nil,
            integration: nil,
            publisher: GhcrPublisher,
            channel: "ghcr",
          ),
        ].freeze,
        T::Array[Entry],
      )

      class << self
        extend T::Sig

        # Build the integration-type -> Repository hash the Resolver consumes.
        #
        # @param project_root [Pathname] project root (threaded to repositories that need it)
        # @return [Hash{Symbol => Repository}]
        sig { params(project_root: Pathname).returns(T::Hash[Symbol, Repository]) }
        def repositories(project_root:)
          context = { project_root: }
          INTEGRATIONS.to_h { |entry| [entry.symbol, build_repository(entry, context)] }
        end

        # Build the integration-type -> VersionScheme hash the Resolver consumes.
        # Schemes are stateless domain services; their only context is the
        # entry's own scheme_args (e.g. which constraint key ExactScheme reads).
        # Scheme-less (purely addressable) types are absent from the hash, so
        # a constraint-shaped ask against one fails the Resolver's
        # no-scheme-registered check loudly.
        #
        # @return [Hash{Symbol => VersionScheme}]
        sig { returns(T::Hash[Symbol, VersionScheme]) }
        def schemes
          INTEGRATIONS.each_with_object({}) do |entry, schemes|
            scheme = entry.scheme
            next unless scheme

            # T.unsafe: the keyword set is entry-declared (scheme_args); the
            # scheme constructors' own sigs validate at runtime.
            schemes[entry.symbol] = T.unsafe(scheme).new(**entry.scheme_args)
          end
        end

        # Build the integration-type -> Locker hash for types whose ecosystem
        # tool owns the whole-set solve. dev deps update runs these before the
        # Resolver so each tool lockfile is materialized when find reads it.
        #
        # @param project_root [Pathname] project root (threaded to lockers that need it)
        # @param ruby_version [String, nil] the exact Ruby the lock pins, for
        #   the bundler-generated Gemfile's `ruby` directive
        # @return [Hash{Symbol => Locker}]
        sig do
          params(
            project_root: Pathname,
            ruby_version: T.nilable(String),
          ).returns(T::Hash[Symbol, Locker])
        end
        def lockers(project_root:, ruby_version: nil)
          context = { project_root:, ruby_version: }
          INTEGRATIONS.each_with_object({}) do |entry, lockers|
            locker = entry.locker
            next unless locker

            # T.unsafe: the keyword set is runtime-selected (locker_needs);
            # the locker constructors' own sigs validate at runtime.
            lockers[entry.symbol] = T.unsafe(locker).new(**T.unsafe(context).slice(*entry.locker_needs))
          end
        end

        # Every integration symbol → the Integration class that installs it,
        # the input to the needs table (IntegrationNeeds). An aliased type
        # maps to its target's class, since its pins install through that
        # instance and so its needs are that class's. Built-in entries only:
        # an integration from outside dev-core arrives as a dependency and
        # its needs come in through that dependency's own manifest (#300).
        #
        # @return [Hash{Symbol => Class}]
        sig { returns(T::Hash[Symbol, T.class_of(Integration)]) }
        def integration_classes
          INTEGRATIONS.each_with_object({}) do |entry, classes|
            klass = entry.integration || alias_target(entry)&.integration
            classes[entry.symbol] = klass if klass
          end
        end

        # Build the integration-type -> Integration hash for `dev deps install`
        # on this build host — the same set on a workstation, a box and inside
        # a build container, each against its own data root.
        #
        # @param project_root [Pathname] project root (threaded to integrations that need it)
        # @param project_name [String] the project's package identity (dev.yml
        #   `name`): what keys the project's own state in the store (the venv)
        # @param store [ArtifactStore] where installed trees and downloaded blobs live (passed to every integration)
        # @param taps [Array<Tap>] Homebrew taps for the brew integration
        # @param pin_taps [Boolean] brew installs from taps checked out at the
        #   lock's commits (BrewIntegration), not brew's API
        # @return [Hash{Symbol => Integration}]
        sig do
          params(
            project_root: Pathname,
            project_name: String,
            store: ArtifactStore,
            taps: T::Array[Tap],
            pin_taps: T::Boolean,
          ).returns(T::Hash[Symbol, Integration])
        end
        def host_integrations(project_root:, project_name:, store:, taps: [], pin_taps: false)
          integrations_for(INTEGRATIONS.select(&:host?), project_root:, project_name:, store:, taps:, pin_taps:)
        end

        # Build the channel-name -> Publisher hash of the write sides the
        # lock **reaches** (dev#422): every publishing entry whose type the
        # lock pins, directly or through an alias — a project pinning only
        # `ruby` installs it through brew, so brew's publisher is its too.
        # The channels `deploy` contributes with no dev.yml line
        # (Dev::ProjectPublishers reads the pins; Dev::ChannelBinder merges
        # the result with the declared channels). Built-in entries only, as
        # every table here: an external publisher arrives through dev#300's
        # SPI.
        #
        # @param project_root [Pathname] project root (threaded to publishers that need it)
        # @param pinned [Array<Symbol>] the integration types the lock pins
        # @param taps [Array<Tap>] the taps the lock pins formulae from (the
        #   brew publisher's destination)
        # @param entries [Array<Entry>] the table to read (tests substitute one)
        # @return [Hash{String => Lifecycle::Publisher}] in table order
        sig do
          params(project_root: Pathname, pinned: T::Array[Symbol], taps: T::Array[Tap], entries: T::Array[Entry])
            .returns(T::Hash[String, Lifecycle::Publisher])
        end
        def publishers(project_root:, pinned:, taps: [], entries: INTEGRATIONS)
          context = { project_root:, taps: }
          reached = entries.select { |entry| pinned.include?(entry.symbol) }.flat_map { |entry| [entry.symbol, entry.install_alias] }
          entries.select { |entry| entry.publishes? && reached.include?(entry.symbol) }.to_h do |entry|
            # T.unsafe: the keyword set is runtime-selected (publisher_needs);
            # the publisher constructors' own sigs validate at runtime.
            publisher = T.unsafe(T.must(entry.publisher)).new(**T.unsafe(context).slice(*entry.publisher_needs))
            [entry.channel_name, T.let(publisher, Lifecycle::Publisher)]
          end
        end

        private

        # Instantiate the given entries' integrations, then alias the types
        # that install through another entry's instance.
        #
        # @param entries [Array<Entry>] the entries that install
        # @param project_root [Pathname]
        # @param project_name [String]
        # @param store [ArtifactStore]
        # @param taps [Array<Tap>]
        # @param pin_taps [Boolean]
        # @return [Hash{Symbol => Integration}]
        sig do
          params(
            entries: T::Array[Entry],
            project_root: Pathname,
            project_name: String,
            store: ArtifactStore,
            taps: T::Array[Tap],
            pin_taps: T::Boolean,
          ).returns(T::Hash[Symbol, Integration])
        end
        def integrations_for(entries, project_root:, project_name:, store:, taps:, pin_taps:)
          context = {
            project_root:,
            project_dir: project_root,
            project_name:,
            taps:,
            pin_taps:,
            brew_env: BrewEnv.new(path: BrewEnv.user_file),
          }
          integrations = entries.to_h do |entry|
            # T.unsafe: each entry's constructor takes a runtime-selected
            # keyword set (integration_needs), which Sorbet cannot check
            # statically; the constructors' own sigs validate at runtime.
            integration = T.unsafe(T.must(entry.integration)).new(
              repository: build_repository(entry, context),
              store:,
              **T.unsafe(context).slice(*entry.integration_needs),
            )
            [entry.symbol, integration]
          end

          # Aliased types share their target's INSTANCE (not just its class):
          # the Installer groups dispatch by instance, so both types' deps
          # arrive in one install_all call and batch artifacts stay whole.
          # An alias whose target has no integration is absent too.
          INTEGRATIONS.each do |entry|
            alias_target = entry.install_alias
            next unless alias_target && integrations.key?(alias_target)

            integrations[entry.symbol] = integrations.fetch(alias_target)
          end
          integrations
        end

        # The entry an aliased type installs through, if the entry is aliased.
        #
        # @param entry [Entry]
        # @return [Entry, nil]
        sig { params(entry: Entry).returns(T.nilable(Entry)) }
        def alias_target(entry)
          target = entry.install_alias
          return nil unless target

          INTEGRATIONS.find { |candidate| candidate.symbol == target }
        end

        # @param entry [Entry]
        # @param context [Hash{Symbol => Object}] available constructor arguments
        # @return [Repository]
        sig { params(entry: Entry, context: T::Hash[Symbol, T.untyped]).returns(Repository) }
        def build_repository(entry, context)
          # T.unsafe: the keyword set is runtime-selected (repository_needs);
          # the repository constructors' own sigs validate at runtime.
          entry.repository.new(**T.unsafe(context).slice(*entry.repository_needs))
        end
      end
    end
  end
end

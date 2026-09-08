# typed: strict
# frozen_string_literal: true

require_relative "package"
require_relative "package_id"
require_relative "package_version"

module Dev
  module Deps
    # Source adapter over one integration's package universe: given an
    # identity, report the versions the backing service offers and the facts
    # attached to them.
    #
    # Facts only — a Fowler-style repository. A Repository never sees a
    # constraint, never selects a version, and has no lifecycle: it is fully
    # functional from construction, a pure function of (id, datastore).
    # Constraint evaluation belongs to the integration's VersionScheme,
    # selection to the Resolver, and whole-set solves (bundle lock) to the
    # integration's Locker. See docs/deps-architecture.md.
    class Repository
      extend T::Sig

      # The universe has no package under the requested identity.
      class PackageNotFoundError < StandardError; end

      # A revision was addressed against an integration whose universe has no
      # continuous space (nothing exists outside the published versions).
      class NoAddressableSpaceError < StandardError; end

      # Report the package under this identity.
      #
      # The probe is the exact version coordinate the declaration pins (a git
      # ref, a release tag, a brew formula suffix), extracted by the
      # integration's VersionScheme#pin. It exists for universes that cannot
      # enumerate — `git ls-remote` lists refs, never reachable SHAs; brew
      # answers for one formula spec at a time — where it is the access path
      # to the version being asked about. Enumerable universes ignore it.
      #
      # It is never a constraint and never selection: a repository must not
      # evaluate range constraints (VersionScheme's job) and must not choose
      # among candidates (the Resolver's job). The declaration's constraint
      # hash, source coordinates (they ride PackageId#source), and install
      # instructions (ScopedDeclaration#materialization, merged into the pin
      # by the Resolver) never reach a repository.
      #
      # @param id [PackageId] the package's identity
      # @param probe [String, nil] pinned version coordinate, as an access
      #   path for non-enumerable universes only
      # @return [Package] the available versions and their facts
      # @raise [PackageNotFoundError] if the universe has no such package
      sig { params(id: PackageId, probe: T.nilable(String)).returns(Package) }
      def find(id, probe: nil)
        raise NotImplementedError, "#{self.class}#find must be implemented"
      end

      # Lift an addressable revision into a version — the continuous-space
      # counterpart of find.
      #
      # Where find queries the discrete published universe (I/O against the
      # backing service), at lifts an address the author already chose: pure,
      # no I/O, ever. The address is trusted at resolve time and
      # dereferenced/verified at install — the same pin-as-assertion
      # semantics a Steam buildid has. No scheme runs over the result and the
      # Resolver mints the pin from it directly: a revision forgoes
      # resolution by definition.
      #
      # Overriding this method is what declares that an integration has a
      # continuous space at all (git commit SHAs, exact Xcode versions); the
      # base refuses, and the Resolver lets that refusal propagate.
      #
      # @param id [PackageId] the package's identity
      # @param revision [String] address in the ecosystem's canonical spelling
      # @return [PackageVersion] the lifted version and its facts
      # @raise [NoAddressableSpaceError] unless the integration overrides
      sig { params(id: PackageId, revision: String).returns(PackageVersion) }
      def at(id, revision)
        raise NoAddressableSpaceError,
          "#{self.class} has no addressable space: #{id.name} cannot be pinned at #{revision.inspect}"
      end
    end
  end
end

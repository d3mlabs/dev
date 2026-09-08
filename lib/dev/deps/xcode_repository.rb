# typed: strict
# frozen_string_literal: true

require_relative "declarations"
require_relative "package"
require_relative "package_id"
require_relative "package_version"
require_relative "repository"

module Dev
  module Deps
    # Reports the Xcode toolchain: a purely addressable universe.
    #
    # Apple publishes no queryable version registry (nothing to enumerate, no
    # hashes to pin), so there is no discrete universe and find refuses. The
    # declared exact version is an address — the DSL's xcode verb mints it as
    # the declaration's revision — and at lifts it as the identity. The pin
    # still rides the resolver -> lockfile pipeline so it lands in deps.lock
    # like every other dependency and the installer/accessor can find it
    # there; existence is verified at install by the xcodes CLI.
    class XcodeRepository < Repository
      extend T::Sig

      # Constraint-shaped asks cannot work here: there is nothing to select
      # over. Declarations arrive as revisions instead.
      class NoEnumerableUniverseError < PackageNotFoundError; end

      # @param id [PackageId]
      # @param probe [String, nil] unused
      # @return [Package] never returns
      # @raise [NoEnumerableUniverseError] always
      sig { override.params(id: PackageId, probe: T.nilable(String)).returns(Package) }
      def find(id, probe: nil)
        raise NoEnumerableUniverseError,
          "Apple publishes no queryable Xcode registry — declare an exact version (e.g. xcode \"26.1.1\")"
      end

      # Lift the declared exact version — resolution is the identity.
      #
      # @param id [PackageId] name is the declaration name
      # @param revision [String] exact Xcode version (e.g. "26.1.1")
      # @return [PackageVersion]
      sig { override.params(id: PackageId, revision: String).returns(PackageVersion) }
      def at(id, revision)
        # An Xcode install is self-contained: Apple ships the whole toolchain.
        PackageVersion.new(version: revision, declarations: Declarations::Resolved.new([]))
      end
    end
  end
end

# typed: strict
# frozen_string_literal: true

require_relative "declarations"
require_relative "package"
require_relative "package_id"
require_relative "package_version"
require_relative "repository"

module Dev
  module Deps
    # Reports Debian-family OS packages: a purely addressable universe.
    #
    # apt publishes versions per distro release (`11.0.0.0~noble-1` is not
    # `11.0.0.0~jammy-1`), so one lock serving every Linux build host has no
    # single version to pin and find refuses. The declared address is the
    # suite — "the current build of this package in its declared source on
    # this host's release" — which the DSL's apt verb mints as the
    # declaration's revision and at lifts as the identity. The pin rides the
    # resolver -> lockfile pipeline like every other dependency; the version
    # that actually lands is the host's fact (`dpkg-query`), reported at
    # install, never locked.
    class AptRepository < Repository
      extend T::Sig

      # Constraint-shaped asks cannot work here: there is nothing portable to
      # select over. Declarations arrive as the suite address instead.
      class NoEnumerableUniverseError < PackageNotFoundError; end

      # @param id [PackageId]
      # @return [Package] never returns
      # @raise [NoEnumerableUniverseError] always
      sig { override.params(id: PackageId).returns(Package) }
      def find(id)
        raise NoEnumerableUniverseError,
          "apt publishes no cross-host version list for #{id.name} — an apt declaration installs the suite's " \
          "current build (apt \"#{id.name}\"); there is no version to select"
      end

      # Lift the suite address — resolution is the identity.
      #
      # @param id [PackageId] name is the package name
      # @param revision [String] the address the DSL minted ("suite")
      # @return [PackageVersion]
      sig { override.params(id: PackageId, revision: String).returns(PackageVersion) }
      def at(id, revision)
        # apt resolves the package's own dependency graph on the host.
        PackageVersion.new(version: revision, declarations: Declarations::Resolved.new([]))
      end
    end
  end
end

# typed: strict
# frozen_string_literal: true

require_relative "declarations"
require_relative "package"
require_relative "package_id"
require_relative "package_version"
require_relative "repository"

module Dev
  module Deps
    # Reports the Wwise SDK: a purely addressable universe.
    #
    # Audiokinetic's version list sits behind an account login, and
    # resolution never holds a credential (the lock must be computable on any
    # machine), so there is no universe to enumerate and find refuses. The
    # declared SDK version is an address — the DSL's wwise verb mints it as
    # the declaration's revision — and at lifts it as the identity. The pin
    # rides the resolver -> lockfile pipeline like every other dependency;
    # existence is verified at install, when wwise-cli downloads it.
    class WwiseRepository < Repository
      extend T::Sig

      # Constraint-shaped asks cannot work here: there is nothing to select
      # over. Declarations arrive as revisions instead.
      class NoEnumerableUniverseError < PackageNotFoundError; end

      # @param id [PackageId]
      # @return [Package] never returns
      # @raise [NoEnumerableUniverseError] always
      sig { override.params(id: PackageId).returns(Package) }
      def find(id)
        raise NoEnumerableUniverseError,
          "Wwise versions are not enumerable without an Audiokinetic login — " \
          "declare exact versions (e.g. wwise \"Wwise\", sdk: \"2023.1.14.8770\", …)"
      end

      # Lift the declared SDK version — resolution is the identity.
      #
      # @param id [PackageId] name is the declaration name
      # @param revision [String] exact SDK version (e.g. "2023.1.14.8770")
      # @return [PackageVersion]
      sig { override.params(id: PackageId, revision: String).returns(PackageVersion) }
      def at(id, revision)
        # An SDK package is self-contained: Audiokinetic ships the whole tree.
        PackageVersion.new(version: revision, declarations: Declarations::Resolved.new([]))
      end
    end
  end
end

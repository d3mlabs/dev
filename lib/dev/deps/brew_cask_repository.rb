# typed: strict
# frozen_string_literal: true

require_relative "declarations"
require_relative "package"
require_relative "package_id"
require_relative "package_version"
require_relative "repository"

module Dev
  module Deps
    # Reports Homebrew casks (:cask integration): an unversioned singleton
    # universe.
    #
    # A separate universe from BrewRepository's formulae because the two are
    # genuinely different package spaces with different facts: Homebrew
    # exposes neither versions nor bottle digests for casks the way it does
    # for formulae, so there is nothing to query — the name's presence is the
    # whole fact. Integrity is delegated to brew at install time, the same
    # nil-hash shape Steam uses.
    class BrewCaskRepository < Repository
      extend T::Sig

      # Version stand-in for casks, whose versions Homebrew does not expose;
      # the Resolver mints it back to a nil pin version.
      UNVERSIONED = ""

      # Report a cask's universe: one unversioned entry.
      #
      # Versioned casks are distinct cask names in Homebrew's own universe
      # (`temurin@21`), so the name is the whole coordinate — there is no
      # suffix fact to select over, and a `version:` constraint on a cask is
      # unsatisfiable by construction (BrewScheme finds no suffix to match,
      # loudly).
      #
      # @param id [PackageId] name is the cask name
      # @return [Package] a singleton universe
      sig { override.params(id: PackageId).returns(Package) }
      def find(id)
        metadata = { "cask" => true }

        Package.new(
          id: id,
          versions: [
            PackageVersion.new(
              version: UNVERSIONED,
              metadata: metadata,
              # brew installs cask dependencies itself.
              declarations: Declarations::ToolOwned.new,
            ),
          ],
        )
      end
    end
  end
end

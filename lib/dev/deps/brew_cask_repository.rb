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
      # The declared suffix (rare for casks) rides metadata so BrewScheme can
      # match it, mirroring the formula shape.
      #
      # @param id [PackageId] name is the cask name
      # @param probe [String, nil] cask version suffix, if declared
      # @return [Package] a singleton universe
      sig { override.params(id: PackageId, probe: T.nilable(String)).returns(Package) }
      def find(id, probe: nil)
        metadata = { "cask" => true }
        metadata["version_suffix"] = probe if probe

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

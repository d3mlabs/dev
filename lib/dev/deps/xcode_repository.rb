# typed: strict
# frozen_string_literal: true

require_relative "declarations"
require_relative "package"
require_relative "package_id"
require_relative "package_version"
require_relative "repository"

module Dev
  module Deps
    # Resolves the `xcode "<version>"` declaration to a pinned Dependency.
    #
    # Xcode has no queryable registry to resolve against (Apple publishes no
    # version API dev could pin hashes from), so resolution is the identity:
    # the declared exact version IS the locked version. This still rides the
    # resolver -> lockfile pipeline so the pin lands in deps.lock like every
    # other dependency and the installer/accessor can find it there.
    class XcodeRepository < Repository
      extend T::Sig

      class MissingVersionError < StandardError; end

      # Report the Xcode universe: the probed version, as a singleton.
      #
      # Apple publishes no queryable version registry, so resolution is the
      # identity — the probe IS the universe.
      #
      # @param id [PackageId] name is the declaration name
      # @param probe [String, nil] the pinned exact version; required
      # @return [Package] a singleton universe
      # @raise [MissingVersionError] when no exact version was declared
      sig { override.params(id: PackageId, probe: T.nilable(String)).returns(Package) }
      def find(id, probe: nil)
        version = probe.to_s
        raise MissingVersionError, "xcode requires an exact version (e.g. xcode \"26.1.1\")" if version.empty?

        # An Xcode install is self-contained: Apple ships the whole toolchain.
        Package.new(
          id: id,
          versions: [PackageVersion.new(version: version, declarations: Declarations::Resolved.new([]))],
        )
      end
    end
  end
end

# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "dependency"
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

      # Report the Xcode universe: the declared version, as a singleton.
      #
      # Apple publishes no queryable version registry, so resolution is the
      # identity — the filter's "version" IS the universe.
      #
      # @param id [PackageId] name is the declaration name
      # @param filter [Hash] locator: "version" (exact, required)
      # @return [Package] a singleton universe
      # @raise [MissingVersionError] when no exact version was declared
      sig { override.params(id: PackageId, filter: T::Hash[String, T.untyped]).returns(Package) }
      def find(id, filter: {})
        version = filter["version"].to_s
        raise MissingVersionError, "xcode requires an exact version (e.g. xcode \"26.1.1\")" if version.empty?

        Package.new(id: id, versions: [PackageVersion.new(version: version)])
      end

      # @param id [Hash] must include "name", "integration", "group", "version"
      # @return [Dependency]
      # @raise [MissingVersionError] when no exact version was declared
      sig { params(id: T::Hash[String, T.untyped]).returns(Dependency) }
      def fetch(id)
        version = id["version"].to_s
        raise MissingVersionError, "xcode requires an exact version (e.g. xcode \"26.1.1\")" if version.empty?

        Dependency.new(
          name: id["name"],
          integration: id["integration"].to_sym,
          group: id["group"].to_sym,
          version: version,
          hash: nil,
          metadata: {},
        )
      end
    end
  end
end

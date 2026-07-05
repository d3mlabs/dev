# frozen_string_literal: true

require_relative "repository"
require_relative "dependency"

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
      class MissingVersionError < StandardError; end

      # @param id [Hash] must include "name", "integration", "group", "version"
      # @return [Dependency]
      # @raise [MissingVersionError] when no exact version was declared
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

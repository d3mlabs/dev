# frozen_string_literal: true

module Dev
  module Deps
    # Source adapter that resolves a single dependency constraint to a Pin.
    #
    # Subclasses (GitRepository, UrlRepository, LuaRocksRegistry, BrewRegistry, …)
    # know how to query their upstream source and return an exact, hashable Pin.
    #
    # Repositories may download an artifact during resolve to compute its
    # integrity hash; the result is stored in Cache for later install.
    class Repository
      # Resolve a named dependency constraint into a Pin.
      #
      # @param name       [String]  dependency name
      # @param constraint [String]  version constraint (tag, semver range, URL, …)
      # @param cache      [Cache]   shared download cache
      # @return [Pin]
      def resolve(name, constraint, cache:)
        raise NotImplementedError, "#{self.class}#resolve must be implemented"
      end

      # Enumerate transitive dependencies of a resolved Pin.
      #
      # Registries with dependency metadata (LuaRocks, CurseForge, Brew) override
      # this to enable transitive resolution. Source-based repos (Git, URL) return
      # an empty array — the user declares everything explicitly.
      #
      # @param pin [Pin]
      # @return [Array<Hash>] each hash has :name and :constraint keys
      def dependencies(pin)
        []
      end
    end
  end
end

# frozen_string_literal: true

module Dev
  module Deps
    # Lifecycle handler for a dependency type.
    #
    # Accepts a Repository and Cache via DI at construction; immutable after
    # construction. Receives all pins for its type at once via install_all —
    # handles per-pin install plus any batch artifacts (e.g. deps.cmake).
    #
    # Subclasses: CmakeIntegration, LuaRocksIntegration, BrewIntegration, …
    class Integration
      attr_reader :repository, :cache

      # @param repository [Repository] source adapter for this integration type
      # @param cache      [Cache]      shared download cache
      def initialize(repository:, cache:)
        @repository = repository
        @cache = cache
        freeze
      end

      # Install all pins of this integration type into the project.
      #
      # Handles per-pin install (extract, luarocks install, brew install, …)
      # and any batch artifacts (e.g. deps.cmake generation for CmakeIntegration).
      #
      # @param pins [Array<Pin>] all pins for this integration type
      # @param root [String]     project root directory
      def install_all(pins, root:)
        raise NotImplementedError, "#{self.class}#install_all must be implemented"
      end
    end
  end
end

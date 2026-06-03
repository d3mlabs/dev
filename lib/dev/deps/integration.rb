# frozen_string_literal: true

module Dev
  module Deps
    # Lifecycle handler for a dependency type.
    #
    # Accepts a Repository and Cache via DI at construction. Receives all
    # dependencies for its type at once via install_all — handles per-dep
    # install plus any batch artifacts (e.g. deps.cmake).
    class Integration
      # @param repository [Repository] source adapter for this integration type
      # @param cache      [Cache]      shared download cache
      def initialize(repository:, cache:)
        @repository = repository
        @cache = cache
      end

      # Install all dependencies of this integration type into the project.
      #
      # @param dependencies [Array<Dependency>] all deps for this integration type
      # @param project_root [Pathname]          root directory of the project
      def install_all(dependencies, project_root:)
        raise NotImplementedError, "#{self.class}#install_all must be implemented"
      end

      private

      attr_reader :repository, :cache
    end
  end
end

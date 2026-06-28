# frozen_string_literal: true

module Dev
  module Deps
    # Source adapter that fetches a dependency by its unique identifier.
    #
    # Returns a Dependency domain object with all fields populated
    # (including transitive dependencies when the source supports it).
    class Repository
      # Fetch a dependency by its unique identifier.
      #
      # @param id [String] unique resource identifier within this repository
      # @return [Dependency]
      def fetch(id)
        raise NotImplementedError, "#{self.class}#fetch must be implemented"
      end

      # Batch hook called once per integration type before any fetch, with all
      # declarations of this type. Repositories whose backing tool resolves the
      # whole set together (e.g. bundler running `bundle lock` once) override
      # this; per-dependency repositories inherit the no-op.
      #
      # @param declarations [Array<DependencyDeclaration>] this type's declarations
      # @return [void]
      def prepare(declarations); end
    end
  end
end

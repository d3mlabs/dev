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
    end
  end
end

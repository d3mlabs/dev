# typed: strict
# frozen_string_literal: true

require "dev/execution_context"

module Dev
  module Builtins
    # The bring-down port of a service dependency — the mirror of ServiceUp,
    # walked by `dev down` in reverse bring-up order before the engine is
    # considered. Same contract: an operation on the project, no argv, no
    # ExecutionContext; a CLI verb exposing it is an adapter over `down`.
    module ServiceDown
      extend T::Sig
      extend T::Helpers
      interface!

      # @param project [ProjectContext] the checkout the service serves
      # @return [void]
      sig { abstract.params(project: ProjectContext).void }
      def down(project:); end
    end
  end
end

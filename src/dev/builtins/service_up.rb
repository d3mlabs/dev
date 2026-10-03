# typed: strict
# frozen_string_literal: true

require "dev/execution_context"

module Dev
  module Builtins
    # The bring-up port of a service dependency — a service this project
    # needs *running* to build and run (the build container, an environment
    # service it executes in; application services it connects to, later).
    #
    # `dev up` orchestrates these: it calls the operation, it does not
    # delegate the user's intent — there is no argv, and no ExecutionContext
    # (a CLI concern), only the project the service is for. A BuiltinCommand
    # that exposes the same operation as a CLI verb includes this and makes
    # its `call` the adapter: `call(args:, context:) = up(project: …)`.
    # Which object implements the port is the composition root's choice.
    module ServiceUp
      extend T::Sig
      extend T::Helpers
      interface!

      # @param project [ProjectContext] the checkout the service serves
      # @return [void]
      sig { abstract.params(project: ProjectContext).void }
      def up(project:); end
    end
  end
end

# typed: strict
# frozen_string_literal: true

require_relative "../value_equality"

module Dev
  module Lifecycle
    # What a target declares for its Builder port: a `build:` line. A target
    # declaring none has nothing to compile; `build` is a no-op for it and
    # `package` runs alone.
    #
    # A declaration, not the port: Ports turns it into a Builder for this
    # checkout. Sealed, so the composition matches exhaustively.
    module BuilderSpec
      extend T::Sig
      extend T::Helpers
      include Kernel
      abstract!
      sealed!

      # The declaration as `dev help` renders it.
      sig { abstract.returns(String) }
      def to_s; end

      # `build: <command>` — a shell command run at the project root with
      # the build in its env (ScriptEnv).
      class Script < T::Struct
        extend T::Sig
        include BuilderSpec
        include Dev::ValueEquality::Derived

        const :command, String

        sig { override.returns(String) }
        def to_s
          command
        end

        # @return [Array] the members that constitute identity
        sig { override.returns(T::Array[T.anything]) }
        def equality_members
          [command]
        end
      end
    end
  end
end

# typed: strict
# frozen_string_literal: true

require_relative "../value_equality"

module Dev
  module Lifecycle
    # What a target declares for its Builder port (dev#192, K1): today the
    # script form — a `build:` line; the integration form (`builder:
    # <name>`, owning the toolchain mapping once) lands with dev#433 as a
    # second variant. A target declaring neither has nothing to compile
    # (Target#builder is nil): `build` is a no-op for it and `package`
    # runs alone — a gem, an org payload.
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

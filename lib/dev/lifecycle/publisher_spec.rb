# typed: strict
# frozen_string_literal: true

require "dev/environment_ref"

module Dev
  module Lifecycle
    # What a channel declares for its Publisher port (dev#192, K5): today
    # the script form — the `deploy` child's `run:` line, with the
    # `environment:` it executes in; the integration form (a publisher the
    # lock contributes, dev#422) lands as a second variant. A channel
    # declaring neither has no protocol and is refused at load.
    #
    # A declaration, not the port: Ports turns it into a Publisher for this
    # checkout. Sealed, so the composition matches exhaustively.
    module PublisherSpec
      extend T::Sig
      extend T::Helpers
      include Kernel
      abstract!
      sealed!

      # Where the protocol comes from, as `dev help deploy` renders it.
      sig { abstract.returns(String) }
      def to_s; end

      # `run: <command>` — a shell command run at the project root once per
      # selected archive, with the archive and its manifest in its env
      # (ScriptEnv.for_deploy). The script owns the protocol and its
      # credentials.
      class Script < T::Struct
        extend T::Sig
        include PublisherSpec

        const :command, String
        # The environment the line executes in, as declared; nil leaves it
        # to the project's default, as a command's absent `environment:` does.
        const :environment, T.nilable(EnvironmentRef), default: nil

        sig { override.returns(String) }
        def to_s = "run: #{command}"

        sig { params(other: Object).returns(T::Boolean) }
        def ==(other) = other.is_a?(Script) && command == other.command && environment == other.environment

        sig { params(other: Object).returns(T::Boolean) }
        def eql?(other) = self == other

        sig { returns(Integer) }
        def hash = [Script, command, environment].hash
      end
    end
  end
end

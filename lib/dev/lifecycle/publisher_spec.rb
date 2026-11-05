# typed: strict
# frozen_string_literal: true

require "dev/environment_ref"

module Dev
  module Lifecycle
    # What a channel declares for its Publisher port (dev#192, K5): the
    # script form — the `deploy` child's `run:` line, with the
    # `environment:` it executes in — or the integration form — the
    # publisher the lock's integration of the channel's name contributes
    # (dev#422), which is what a child with no `run:` means. The lock is
    # not read here: Integration is a *reference*, bound at load by the
    # composition root against the publishers the lock contributes, as an
    # `environment:` is bound against its images; a reference nothing
    # contributes is refused there, naming both fixes.
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
      # credentials. On a channel the lock also contributes, the `run:`
      # **replaces** the integration's publisher (dev#192, K1b).
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

      # The publisher the lock's integration named `name` contributes — the
      # channel's own name, since a lock-contributed channel is the
      # integration's (`deploy steam` is the `steam` integration's write
      # side). A black box over read-only archives: it runs where dev runs,
      # with no `environment:` to place.
      class Integration < T::Struct
        extend T::Sig
        include PublisherSpec

        const :name, String

        sig { override.returns(String) }
        def to_s = "publisher: #{name}"

        sig { params(other: Object).returns(T::Boolean) }
        def ==(other) = other.is_a?(Integration) && name == other.name

        sig { params(other: Object).returns(T::Boolean) }
        def eql?(other) = self == other

        sig { returns(Integer) }
        def hash = [Integration, name].hash
      end
    end
  end
end

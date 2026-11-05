# typed: strict
# frozen_string_literal: true

require_relative "artifact"

module Dev
  module Lifecycle
    # The protocol port of a channel (dev#192, K5): what ships the selected
    # archives to the destination. Two kinds stand behind it — a script,
    # the channel's `run:` line, for an endpoint no integration knows (the
    # gamebox, a PC's sshd); and an integration's publisher, contributed by
    # the lock (dev#422) — and dev's stage is the same over both: it
    # selects the artifacts, checks them, hands them over and records what
    # happened. The port owns its own credentials (`dev cred` from a
    # script's first line; the Credentials provider inside an integration)
    # — nothing of them is in dev.yml.
    #
    # Two constraints keep the port honest, both of which are what make
    # "deployed" mean something: the archives are read-only input — unpack
    # and wrap, never rebuild or alter — and what dev records of the
    # upload is its receipt (dev#423), not anything the port materialised
    # on the way.
    module Publisher
      extend T::Sig
      extend T::Helpers
      interface!

      # Ship the selected artifacts — one per accepted build the channel
      # resolved — to the destination.
      #
      # @param artifacts [Array<Artifact>] in the channel's accept order
      # @param channel [Channel] the destination, for the env and the messages
      # @return [void]
      sig { abstract.params(artifacts: T::Array[Artifact], channel: Channel).void }
      def publish(artifacts, channel:); end
    end
  end
end

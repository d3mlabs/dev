# typed: strict
# frozen_string_literal: true

require_relative "artifact"
require_relative "receipt"

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
    # and wrap, never rebuild or alter — and the Receipt is the output:
    # what dev records of the upload (as a GitHub Deployment, dev#423) is
    # the receipt plus what dev knew going in, never anything the port
    # materialised on the way.
    module Publisher
      extend T::Sig
      extend T::Helpers
      interface!

      # Ship the selected artifacts — one per accepted build the channel
      # resolved — to the destination.
      #
      # @param artifacts [Array<Artifact>] in the channel's accept order
      # @param channel [Channel] the destination, for the env and the messages
      # @return [Receipt] what the publisher says of the upload
      sig { abstract.params(artifacts: T::Array[Artifact], channel: Channel).returns(Receipt) }
      def publish(artifacts, channel:); end
    end
  end
end

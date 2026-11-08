# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "receipt"
require_relative "shipment"
require_relative "track"

module Dev
  module Lifecycle
    # The protocol port of a channel (dev#192, K5): what ships the selected
    # archives to the destination. Two kinds stand behind it — a script,
    # the channel's `run:` line, for an endpoint no integration knows (the
    # gamebox, a PC's sshd); and an integration's publisher, contributed by
    # the lock through the `publisher:` port of its Registry entry
    # (dev#422) — and dev's stage is the same over both: it selects the
    # archives, checks them, hands them over with the track and records
    # what happened. The port owns its own credentials (`dev cred` from a
    # script's first line; the Credentials provider inside an integration)
    # — nothing of them is in dev.yml.
    #
    # The publisher is a black box: it takes the archives — Shipments, one
    # per build, each carrying where it came from (the store, or a
    # release; dev#425) — does whatever the destination needs — nothing,
    # for most channels; for a store, unpacking into depot directories and
    # writing the upload's own descriptors — and uploads. Two constraints
    # keep the box honest, both of which are what make "deployed" mean
    # something: the archives are **read-only input** — unpack and wrap,
    # never rebuild or alter — and the Receipt is the output: what dev
    # records of the upload (as a GitHub Deployment, dev#423) is the
    # receipt plus what dev knew going in, never anything the port
    # materialised on the way. What it materialises lives in its
    # **scratch**, the channel's own directory under the project's store
    # (`<data root>/artifacts/<project>/.<channel>/`, Store#scratch): the
    # publisher's to create, lay out and reuse; nothing in dev.yml or the
    # verbs names it. Partial sets are the publisher's call (Steam refuses
    # a build missing a depot; an rsync does not care).
    module Publisher
      extend T::Sig
      extend T::Helpers
      interface!

      # Ship the selected archives — one per accepted build the channel
      # resolved — to the destination, on the track the source decided.
      #
      # @param shipments [Array<Shipment>] in the channel's accept order
      # @param channel [Channel] the destination, for the env and the messages
      # @param track [Track] testing for archives from the store, live for a release's
      # @param scratch [Pathname] the channel's scratch directory in the store; may not exist yet
      # @return [Receipt] what the publisher says of the upload
      sig { abstract.params(shipments: T::Array[Shipment], channel: Channel, track: Track, scratch: Pathname).returns(Receipt) }
      def publish(shipments, channel:, track:, scratch:); end
    end
  end
end

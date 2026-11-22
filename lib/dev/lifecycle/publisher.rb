# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "head_strategy"
require_relative "receipt"
require_relative "shipment"
require_relative "track"

module Dev
  module Lifecycle
    # The protocol port of a channel: ships the selected archives to the
    # destination. Two kinds stand behind it: a script (the channel's `run:`
    # line) and an integration's publisher, contributed by the lock through
    # its registry entry. Dev's stage is the same over both: it selects the
    # archives, checks them, hands them over with the track and records
    # what happened. The port owns its own credentials; nothing of them is
    # in dev.yml.
    #
    # Two constraints hold for every publisher. The archives are read-only
    # input: unpack and wrap, never rebuild or alter. The Receipt is the
    # output: what dev records of the upload is the receipt plus what dev
    # knew going in. Whatever a publisher materialises lives in its scratch,
    # the channel's own directory under the project's store (Store#scratch).
    #
    # Every channel also has a **head** — what a follower installs when it
    # asks for nothing in particular — and the port declares how its
    # destination keeps it (HeadStrategy): a pointer `deploy` moves, or
    # versions dev computes the head over (Head.derive). The rule that
    # `release` never moves a head and `deploy` moves exactly one is dev's
    # on every channel; the declaration is what gives it a mechanism.
    module Publisher
      extend T::Sig
      extend T::Helpers
      interface!

      # How the destination keeps its head. A fact about the destination,
      # fixed for the channel's kind, so no arguments: a publisher answers
      # the same whatever is shipped.
      #
      # @return [HeadStrategy]
      sig { abstract.returns(HeadStrategy) }
      def head_strategy; end

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

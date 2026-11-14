# typed: strict
# frozen_string_literal: true

require "dev/lifecycle"

module Dev
  module Cli
    # The composition root's step between parsing dev.yml and building
    # `deploy`: the project's channel set is the
    # declared channels **merged** with the ones the lock contributes, by
    # name, under one rule — the one place a project declaration meets a
    # lifecycle builtin:
    #
    # - a declared channel with `run:` is a script channel; on a name the
    #   lock also contributes it **replaces** that publisher (the `run:` is
    #   the protocol; dev's stage still selects, checks and records);
    # - a declared channel without `run:` **configures** the lock's
    #   publisher of its name — its `targets:` is the accept set, the
    #   protocol is the integration's — and when the lock contributes none
    #   it binds with a **Fault** saying why — this dev ships no such
    #   publisher, or the lock pins no type reaching it — and what to do
    #   (#faults): it lists, and `deploy <channel>` refuses with the
    #   fault; nothing else does
    #   (a manifest ahead of the installed dev must not take
    #   `dev deps install` down with it);
    # - a contributed channel the project does not declare appears as it is,
    #   accepting every packageable build (the `release: {}` default), or
    #   not at all when the project has nothing packageable to send it.
    #
    # This is the "third merge case" of CommandRepository#merge, applied to
    # channels rather than command nodes: the loader lifts `deploy`'s
    # children out of the command tree (ChannelParser), so no `deploy`
    # child ever lands on a builtin slot — the merge happens here, before
    # the tree exists, as every lock-referencing name in dev.yml is bound
    # at load (PlacementBinder for `environment:`).
    #
    # The contributed publishers and the targets are fixed for a checkout
    # and constructor-owned; the declared channels are per call.
    class ChannelBinder
      extend T::Sig

      # Why a declared channel has no protocol, and what to do.
      # `summary` is the cause alone, for `dev help deploy`'s Protocol line;
      # `message` is the refusal `deploy <channel>` raises, cause and fixes.
      class Fault < T::Struct
        const :summary, String
        const :message, String
      end

      # @param publishers [Hash{String => Lifecycle::Publisher}] the publishers
      #   the lock contributes, by channel name (ProjectPublishers#contributed)
      # @param reach [Hash{String => Array<Symbol>}] every channel this dev
      #   could contribute, with the types whose pin reaches it
      #   (ProjectPublishers#reach) — tells a publisher this dev lacks from
      #   one the lock does not pin
      # @param targets [Array<Lifecycle::Target>] the project's declared targets
      sig do
        params(
          publishers: T::Hash[String, Lifecycle::Publisher],
          reach: T::Hash[String, T::Array[Symbol]],
          targets: T::Array[Lifecycle::Target],
        ).void
      end
      def initialize(publishers:, reach:, targets:)
        @publishers = publishers
        @reach = reach
        @targets = targets
      end

      # The project's channels: the declared ones as declared (a protocol-less
      # one included — see #faults), then the contributed ones the project
      # did not declare, in registry order.
      #
      # @param declared [Hash{String => Lifecycle::Channel}] the manifest's
      #   channels, in declaration order
      # @return [Hash{String => Lifecycle::Channel}]
      sig { params(declared: T::Hash[String, Lifecycle::Channel]).returns(T::Hash[String, Lifecycle::Channel]) }
      def bind(declared)
        contributed = @publishers.keys.reject { |name| declared.key?(name) }.filter_map { |name| contributed_channel(name) }
        declared.merge(contributed.to_h { |channel| [channel.name, channel] })
      end

      # The declared channels without a protocol, each with its Fault: it
      # declares no `run:` and the lock contributes no publisher of its
      # name — because this dev ships none (a release ahead of the
      # installed dev: `dev up` once one does), or because deps.lock pins
      # no type that reaches it (depend on one, `dev deps update`).
      #
      # @param declared [Hash{String => Lifecycle::Channel}] the manifest's channels
      # @return [Hash{String => Fault}] channel name => fault
      sig { params(declared: T::Hash[String, Lifecycle::Channel]).returns(T::Hash[String, Fault]) }
      def faults(declared)
        declared.filter_map do |name, channel|
          spec = channel.publisher
          next unless spec.is_a?(Lifecycle::PublisherSpec::Integration) && !@publishers.key?(spec.name)

          [name, protocol_fault(channel, spec)]
        end.to_h
      end

      private

      # @param channel [Lifecycle::Channel] a declared channel without a protocol
      # @param spec [Lifecycle::PublisherSpec::Integration] the publisher it names
      # @return [Fault] the cause, and the refusal naming it with both fixes
      sig { params(channel: Lifecycle::Channel, spec: Lifecycle::PublisherSpec::Integration).returns(Fault) }
      def protocol_fault(channel, spec)
        types = @reach[spec.name]
        summary, fix =
          if types.nil?
            ["this dev ships no `#{spec.name}` publisher", "`dev up` once a release ships it"]
          else
            pins = types.size == 1 ? "no `#{spec.name}`" : "none of #{types.map { |type| "`#{type}`" }.join(", ")}"
            ["deps.lock pins #{pins}", "depend on one in dependencies.rb and `dev deps update`"]
          end
        Fault.new(
          summary:,
          message: "channel 'deploy #{channel}' has no protocol: it declares no `run:` and #{summary} — #{fix}, " \
                   "or declare `run:` (a script shipping `$DEV_ARTIFACT`)",
        )
      end

      # A contributed channel as it stands undeclared: the integration's
      # publisher over every packageable build. nil when no target is
      # packageable — a channel accepting nothing has no meaning, so it
      # does not appear (dev's there-iff-it-has-meaning rule).
      #
      # @param name [String] the channel's name
      # @return [Lifecycle::Channel, nil]
      sig { params(name: String).returns(T.nilable(Lifecycle::Channel)) }
      def contributed_channel(name)
        accepts = @targets.select(&:packageable?).map { |target| Lifecycle::BuildPattern.new(target:) }
        return nil if accepts.empty?

        Lifecycle::Channel.new(
          name:,
          desc: "Ship through the lock's #{name} publisher",
          accepts:,
          publisher: Lifecycle::PublisherSpec::Integration.new(name:),
        )
      end
    end
  end
end

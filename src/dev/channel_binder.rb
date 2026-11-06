# typed: strict
# frozen_string_literal: true

require "dev/lifecycle"

module Dev
  # The composition root's step between parsing dev.yml and building
  # `deploy` (dev#192 K1b, K5; dev#422): the project's channel set is the
  # declared channels **merged** with the ones the lock contributes, by
  # name, under one rule — the one place a project declaration meets a
  # lifecycle builtin:
  #
  # - a declared channel with `run:` is a script channel; on a name the
  #   lock also contributes it **replaces** that publisher (the `run:` is
  #   the protocol; dev's stage still selects, checks and records);
  # - a declared channel without `run:` **configures** the lock's
  #   publisher of its name — its `targets:` is the accept set, the
  #   protocol is the integration's — and is refused here when the lock
  #   contributes none, naming both fixes;
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

    # A declared channel with neither `run:` nor a publisher the lock
    # contributes under its name: no protocol.
    class ChannelProtocolError < ArgumentError; end

    # @param publishers [Hash{String => Lifecycle::Publisher}] the publishers
    #   the lock contributes, by channel name (ProjectPublishers#contributed)
    # @param targets [Array<Lifecycle::Target>] the project's declared targets
    sig { params(publishers: T::Hash[String, Lifecycle::Publisher], targets: T::Array[Lifecycle::Target]).void }
    def initialize(publishers:, targets:)
      @publishers = publishers
      @targets = targets
    end

    # The project's channels: the declared ones, each with a protocol, then
    # the contributed ones the project did not declare, in registry order.
    #
    # @param declared [Hash{String => Lifecycle::Channel}] the manifest's
    #   channels, in declaration order
    # @return [Hash{String => Lifecycle::Channel}]
    # @raise [ChannelProtocolError]
    sig { params(declared: T::Hash[String, Lifecycle::Channel]).returns(T::Hash[String, Lifecycle::Channel]) }
    def bind(declared)
      declared.each_value { |channel| assert_protocol!(channel) }
      contributed = @publishers.keys.reject { |name| declared.key?(name) }.filter_map { |name| contributed_channel(name) }
      declared.merge(contributed.to_h { |channel| [channel.name, channel] })
    end

    private

    # @param channel [Lifecycle::Channel] a declared channel
    # @return [void]
    # @raise [ChannelProtocolError]
    sig { params(channel: Lifecycle::Channel).void }
    def assert_protocol!(channel)
      spec = channel.publisher
      return unless spec.is_a?(Lifecycle::PublisherSpec::Integration) && !@publishers.key?(spec.name)

      contributes = @publishers.empty? ? "none" : @publishers.keys.join(", ")
      raise ChannelProtocolError,
        "channel 'deploy #{channel}' has no protocol: it declares no `run:` and the lock contributes no `#{spec.name}` " \
          "publisher (it contributes: #{contributes}) — declare `run:` (a script shipping `$DEV_ARTIFACT`), or depend on " \
          "an integration whose publisher knows the endpoint in dependencies.rb (d3mlabs/dev#192)"
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

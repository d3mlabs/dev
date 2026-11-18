# typed: strict
# frozen_string_literal: true

require "dev/enrolled_runner_lookup"
require "dev/settings"
require_relative "flag"
require_relative "dispatch"
require_relative "host_rule"
require_relative "placement"
require_relative "remote_dispatches"

module Dev
  module Cli
    # The one decision site of where a lifecycle verb executes: a build's
    # bound placement — its target's `environment:` for the
    # build's platform, as TargetPlacement answers it — against the host
    # rule, then against the hosts the remote dispatch can reach. In order:
    #
    # 1. `--runner <label>` forces the remote dispatch to that label,
    #    whatever the placement — a Win64 build-check on the hosted pool
    #    from a box that could build it natively.
    # 2. `--container` forces the project's own container of the build's
    #    image — a flag, not a label, because a runner may be
    #    labelled `local` and `host` is `environment:`'s reserved word. A
    #    `host` build has no image to run a container of: refused.
    # 3. `host` is native here.
    # 4. An image is native when the host rule passes for it — this
    #    machine was provisioned from it (the box, a hosted runner) — or
    #    when this dev already runs inside a container of it (the container
    #    cannot enter another; one that is not the image's is drift,
    #    refused as CommandRunner refuses it).
    # 5. Otherwise the verb leaves the machine: to the label `lifecycle.runner`
    #    names (`dev config set`, a standing `--runner`), else to the repo's
    #    enrolled runner when GitHub lists one online, else to the local
    #    container — the degenerate runner, last.
    #
    # The same rule CommandRunner places a project command by, read for a
    # verb: the verb never enters a container itself — its seam is a port in
    # this process — so a non-native image is not "run it in a container"
    # but "run the verb where the image is". Whether the host chosen can
    # carry the verb from here is the transport's to refuse
    # (Transport#assert_ready!): a verb already inside an Actions job never
    # leaves for a runner, and the Actions transport is the one that says
    # so.
    class DispatchResolver
      extend T::Sig

      RUNNER_FLAG = "--runner"
      CONTAINER_FLAG = "--container"

      # The dispatch flags of every verb that can leave the machine.
      FLAGS = T.let(
        [
          Cli::Flag.new(RUNNER_FLAG, takes_value: true, desc: "run the verb on the runners carrying this label (forces the remote dispatch)"),
          Cli::Flag.new(CONTAINER_FLAG, desc: "run the verb in the project's container of the build's image (forces the local container)"),
        ].freeze,
        T::Array[Cli::Flag],
      )

      # `--runner` and `--container` name two different hosts for one verb.
      class ConflictingDispatchFlagsError < ArgumentError; end

      # `--container` for a build placed on the host: there is no image to
      # run a container of.
      class NoContainerForHostError < RuntimeError; end

      # @param host_rule [HostRule] whether an image's work runs on this
      #   machine — the same instance the command runner and `dev help` read
      # @param remotes [RemoteDispatches] builds the dispatch for a host chosen here
      # @param enrolled [EnrolledRunnerLookup] whether the repo's enrolled runner is online
      # @param settings [Settings] the standing `lifecycle.runner`
      sig do
        params(
          host_rule: HostRule,
          remotes: RemoteDispatches,
          enrolled: EnrolledRunnerLookup,
          settings: Settings,
        ).void
      end
      def initialize(host_rule:, remotes:, enrolled: EnrolledRunnerLookup.new, settings: Settings.new)
        @host_rule = host_rule
        @remotes = remotes
        @enrolled = enrolled
        @settings = settings
      end

      # Where a verb over a build placed at +placement+ executes.
      #
      # @param placement [Placement] the build's bound environment
      # @param subject [String] the build's name, for the refusals
      # @param runner [String, nil] a label `--runner` named; nil to resolve
      # @param container [Boolean] whether `--container` forces the local container
      # @return [Dispatch] Native when the seam runs here; Remote otherwise
      # @raise [ConflictingDispatchFlagsError] when both flags are given
      # @raise [NoContainerForHostError] when `--container` meets a `host` placement
      # @raise [HostRule::ContainerDriftError] inside a container that is not the image's
      # @raise [RunnerRegistry::QueryError] when GitHub cannot say whether the enrolled runner is online
      sig { params(placement: Placement, subject: String, runner: T.nilable(String), container: T::Boolean).returns(Dispatch) }
      def resolve(placement, subject:, runner: nil, container: false)
        if runner && container
          raise ConflictingDispatchFlagsError, "`#{subject}`: #{RUNNER_FLAG} #{runner} and #{CONTAINER_FLAG} name two hosts for one verb; pick one"
        end
        return @remotes.actions_runner(runner) if runner

        case placement
        when Placement::Host
          if container
            raise NoContainerForHostError, "`#{subject}` is placed on the host (`environment: host`): there is no image to run a container of"
          end

          Dispatch::Native.new
        when Placement::Image
          container ? force_container(placement.image) : resolve_image(placement.image)
        else
          # simplecov:disable — the sealed placement has no third shape;
          # T.absurd keeps the static proof.
          T.absurd(placement)
          # simplecov:enable
        end
      end

      private

      # @param image [EnvironmentImage] the build's environment
      # @return [Dispatch]
      # @raise [HostRule::ContainerDriftError]
      sig { params(image: EnvironmentImage).returns(Dispatch) }
      def resolve_image(image)
        @host_rule.assert_container_is!(image) if @host_rule.inside_container?
        return Dispatch::Native.new unless @host_rule.enters_container?(image)

        label = @settings.lifecycle_runner || @enrolled.available&.label
        label ? @remotes.actions_runner(label) : @remotes.local_container(image)
      end

      # `--container`: the image's container, unless this dev already runs
      # inside it — then the container is already entered, and the verb is
      # native (a container that is not the image's is drift, refused).
      #
      # @param image [EnvironmentImage]
      # @return [Dispatch]
      # @raise [HostRule::ContainerDriftError]
      sig { params(image: EnvironmentImage).returns(Dispatch) }
      def force_container(image)
        return @remotes.local_container(image) unless @host_rule.inside_container?

        @host_rule.assert_container_is!(image)
        Dispatch::Native.new
      end
    end
  end
end

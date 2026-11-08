# typed: strict
# frozen_string_literal: true

require "dev/actions_job_context"
require "dev/enrolled_runner_lookup"
require "dev/settings"
require_relative "cli/flag"
require_relative "dispatch"
require_relative "host_rule"
require_relative "placement"
require_relative "remote_dispatches"

module Dev
  # The one decision site of where a lifecycle verb executes (dev#192,
  # K8): a build's bound placement — its target's `environment:` for the
  # build's platform, as TargetPlacement answers it — against the host
  # rule, then against the hosts the remote dispatch can reach. In order:
  #
  # 1. `--runner <label>` forces the remote dispatch to that label,
  #    whatever the placement — a Win64 build-check on the hosted pool
  #    from a box that could build it natively.
  # 2. `--container` forces the project's own container of the build's
  #    image (dev#421) — a flag, not a label, because a runner may be
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
  #    container — the degenerate runner, last (K9).
  #
  # The same rule CommandRunner places a project command by, read for a
  # verb: the verb never enters a container itself — its seam is a port in
  # this process — so a non-native image is not "run it in a container"
  # but "run the verb where the image is". And a verb already running in
  # an Actions job never leaves: a runner that finds itself not to be the
  # build's environment is misprovisioned, and a job dispatching a job
  # would hide that behind a loop.
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

    # A verb inside an Actions job would leave the machine: the runner is
    # not the build's environment.
    class DispatchFromJobError < RuntimeError; end

    # @param host_rule [HostRule] whether an image's work runs on this
    #   machine — the same instance the command runner and `dev help` read
    # @param remotes [RemoteDispatches] builds the dispatch for a host chosen here
    # @param enrolled [EnrolledRunnerLookup] whether the repo's enrolled runner is online
    # @param settings [Settings] the standing `lifecycle.runner`
    # @param inside_job [Boolean] whether this dev runs inside an Actions job
    sig do
      params(
        host_rule: HostRule,
        remotes: RemoteDispatches,
        enrolled: EnrolledRunnerLookup,
        settings: Settings,
        inside_job: T::Boolean,
      ).void
    end
    def initialize(host_rule:, remotes:, enrolled: EnrolledRunnerLookup.new, settings: Settings.new, inside_job: ActionsJobContext.inside?)
      @host_rule = host_rule
      @remotes = remotes
      @enrolled = enrolled
      @settings = settings
      @inside_job = inside_job
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
    # @raise [DispatchFromJobError] when the verb would leave an Actions job
    # @raise [RunnerRegistry::QueryError] when GitHub cannot say whether the enrolled runner is online
    sig { params(placement: Placement, subject: String, runner: T.nilable(String), container: T::Boolean).returns(Dispatch) }
    def resolve(placement, subject:, runner: nil, container: false)
      if runner && container
        raise ConflictingDispatchFlagsError, "`#{subject}`: #{RUNNER_FLAG} #{runner} and #{CONTAINER_FLAG} name two hosts for one verb; pick one"
      end
      return actions_runner(runner, subject:) if runner

      case placement
      when Placement::Host
        if container
          raise NoContainerForHostError, "`#{subject}` is placed on the host (`environment: host`): there is no image to run a container of"
        end

        Dispatch::Native.new
      when Placement::Image
        container ? force_container(placement.image, subject:) : resolve_image(placement.image, subject:)
      else
        # simplecov:disable — the sealed placement has no third shape;
        # T.absurd keeps the static proof.
        T.absurd(placement)
        # simplecov:enable
      end
    end

    private

    # @param image [EnvironmentImage] the build's environment
    # @param subject [String]
    # @return [Dispatch]
    # @raise [HostRule::ContainerDriftError]
    # @raise [DispatchFromJobError]
    sig { params(image: EnvironmentImage, subject: String).returns(Dispatch) }
    def resolve_image(image, subject:)
      @host_rule.assert_container_is!(image) if @host_rule.inside_container?
      return Dispatch::Native.new unless @host_rule.enters_container?(image)

      label = @settings.lifecycle_runner || @enrolled.available&.label
      label ? actions_runner(label, subject:) : local_container(image, subject:)
    end

    # `--container`: the image's container, unless this dev already runs
    # inside it — then the container is already entered, and the verb is
    # native (a container that is not the image's is drift, refused).
    #
    # @param image [EnvironmentImage]
    # @param subject [String]
    # @return [Dispatch]
    # @raise [HostRule::ContainerDriftError]
    # @raise [DispatchFromJobError]
    sig { params(image: EnvironmentImage, subject: String).returns(Dispatch) }
    def force_container(image, subject:)
      return local_container(image, subject:) unless @host_rule.inside_container?

      @host_rule.assert_container_is!(image)
      Dispatch::Native.new
    end

    # @param label [String]
    # @param subject [String]
    # @return [Dispatch::Remote]
    # @raise [DispatchFromJobError]
    sig { params(label: String, subject: String).returns(Dispatch::Remote) }
    def actions_runner(label, subject:)
      assert_leaving!(subject:, to: "runner `#{label}`")
      @remotes.actions_runner(label)
    end

    # @param image [EnvironmentImage]
    # @param subject [String]
    # @return [Dispatch::Remote]
    # @raise [DispatchFromJobError]
    sig { params(image: EnvironmentImage, subject: String).returns(Dispatch::Remote) }
    def local_container(image, subject:)
      assert_leaving!(subject:, to: "a container of #{image.name}")
      @remotes.local_container(image)
    end

    # @param subject [String]
    # @param to [String] where the verb would go
    # @return [void]
    # @raise [DispatchFromJobError]
    sig { params(subject: String, to: String).void }
    def assert_leaving!(subject:, to:)
      return unless @inside_job

      raise DispatchFromJobError,
        "`#{subject}` would leave this Actions job for #{to}: a job never dispatches a job — " \
          "this runner is not the build's environment (#{@host_rule.host}); provision it from the image, or name a runner that is"
    end
  end
end

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
  # 2. `host` is native here.
  # 3. An image is native when the host rule passes for it — this
  #    machine was provisioned from it (the box, a hosted runner) — or
  #    when this dev already runs inside a container of it (the container
  #    cannot enter another; one that is not the image's is drift,
  #    refused as CommandRunner refuses it).
  # 4. Otherwise the verb leaves the machine: to the label `lifecycle.runner`
  #    names (`dev config set`, a standing `--runner`), else to the repo's
  #    enrolled runner when GitHub lists one online, else — until the
  #    local container lands (dev#421) — a refusal naming the three ways
  #    to get one.
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

    # The dispatch flags of every verb that can leave the machine.
    FLAGS = T.let(
      [Cli::Flag.new(RUNNER_FLAG, takes_value: true, desc: "run the verb on the runners carrying this label (forces the remote dispatch)")].freeze,
      T::Array[Cli::Flag],
    )

    # The build's image is not this machine's, and no runner is there to
    # carry the verb: none enrolled for the repo, none named.
    class RemoteDispatchUnavailableError < RuntimeError; end

    # A verb inside an Actions job would leave the machine: the runner is
    # not the build's environment.
    class DispatchFromJobError < RuntimeError; end

    # @param host_rule [HostRule] whether an image's work runs on this
    #   machine — the same instance the command runner and `dev help` read
    # @param remotes [RemoteDispatches] builds the dispatch for a label chosen here
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
    # @param subject [String] the build's name, for the refusal
    # @param runner [String, nil] a label `--runner` named; nil to resolve
    # @return [Dispatch] Native when the seam runs here; Remote otherwise
    # @raise [HostRule::ContainerDriftError] inside a container that is not the image's
    # @raise [RemoteDispatchUnavailableError] when the image is not this machine's and no runner is there
    # @raise [DispatchFromJobError] when the verb would leave an Actions job
    # @raise [RunnerRegistry::QueryError] when GitHub cannot say whether the enrolled runner is online
    sig { params(placement: Placement, subject: String, runner: T.nilable(String)).returns(Dispatch) }
    def resolve(placement, subject:, runner: nil)
      return remote(runner, subject:) if runner

      case placement
      when Placement::Host then Dispatch::Native.new
      when Placement::Image then resolve_image(placement.image, subject:)
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
    # @raise [RemoteDispatchUnavailableError]
    # @raise [DispatchFromJobError]
    sig { params(image: EnvironmentImage, subject: String).returns(Dispatch) }
    def resolve_image(image, subject:)
      @host_rule.assert_container_is!(image) if @host_rule.inside_container?
      return Dispatch::Native.new unless @host_rule.enters_container?(image)

      remote(remote_label(image, subject:), subject:)
    end

    # The label a verb leaving this machine goes to: the standing
    # preference, else the enrolled runner when it is online.
    #
    # @param image [EnvironmentImage]
    # @param subject [String]
    # @return [String]
    # @raise [RemoteDispatchUnavailableError]
    sig { params(image: EnvironmentImage, subject: String).returns(String) }
    def remote_label(image, subject:)
      @settings.lifecycle_runner || @enrolled.available&.label || raise(
        RemoteDispatchUnavailableError,
        "`#{subject}` builds in #{image.name}, and this host was not provisioned from it (#{@host_rule.host}); " \
          "no runner is enrolled for this repo and online — enroll one with `dev runner register` on a host " \
          "provisioned from #{image.name}, name a pool with `#{RUNNER_FLAG} <label>`, or set a standing one with " \
          "`dev config set #{Settings::LIFECYCLE_RUNNER_KEY} <label>`",
      )
    end

    # @param label [String]
    # @param subject [String]
    # @return [Dispatch::Remote]
    # @raise [DispatchFromJobError]
    sig { params(label: String, subject: String).returns(Dispatch::Remote) }
    def remote(label, subject:)
      if @inside_job
        raise DispatchFromJobError,
          "`#{subject}` would leave this Actions job for runner `#{label}`: a job never dispatches a job — " \
            "this runner is not the build's environment (#{@host_rule.host}); provision it from the image, or name a runner that is"
      end

      @remotes.actions_runner(label)
    end
  end
end

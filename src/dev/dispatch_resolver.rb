# typed: strict
# frozen_string_literal: true

require_relative "dispatch"
require_relative "host_rule"
require_relative "placement"

module Dev
  # The one decision site of where a lifecycle verb executes (dev#192,
  # K8): a build's bound placement — its target's `environment:` for the
  # build's platform, as TargetPlacement answers it — against the host
  # rule. `host` is native here. An image is native when the host rule
  # passes for it — this machine was provisioned from it (the box, a
  # hosted runner) — or when this dev already runs inside a container of
  # it (the container cannot enter another; one that is not the image's
  # is drift, refused as CommandRunner refuses it). Any other machine
  # needs the remote dispatch — the enrolled runner, else the local
  # container (dev#420, dev#421) — which this resolver refuses until it
  # lands, naming what would make the build native.
  #
  # The same rule CommandRunner places a project command by, read for a
  # verb: the verb never enters a container itself — its seam is a port in
  # this process — so a non-native image is not "run it in a container"
  # but "run the verb where the image is".
  class DispatchResolver
    extend T::Sig

    # The build's image is not this machine's, and dev has no remote
    # dispatch yet to carry the verb to a host that has it.
    class RemoteDispatchUnavailableError < RuntimeError; end

    # @param host_rule [HostRule] whether an image's work runs on this
    #   machine — the same instance the command runner and `dev help` read
    sig { params(host_rule: HostRule).void }
    def initialize(host_rule:)
      @host_rule = host_rule
    end

    # Where a verb over a build placed at +placement+ executes.
    #
    # @param placement [Placement] the build's bound environment
    # @param subject [String] the build's name, for the refusal
    # @return [Dispatch] Native when the seam runs here
    # @raise [HostRule::ContainerDriftError] inside a container that is not the image's
    # @raise [RemoteDispatchUnavailableError] when the image is not this machine's
    sig { params(placement: Placement, subject: String).returns(Dispatch) }
    def resolve(placement, subject:)
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
    sig { params(image: EnvironmentImage, subject: String).returns(Dispatch) }
    def resolve_image(image, subject:)
      @host_rule.assert_container_is!(image) if @host_rule.inside_container?
      return Dispatch::Native.new unless @host_rule.enters_container?(image)

      raise RemoteDispatchUnavailableError,
        "`#{subject}` builds in #{image.name}, and this host was not provisioned from it (#{@host_rule.host}); " \
          "run it on a host that was — a box or runner provisioned from #{image.name} — " \
          "or from inside its container (dev has no remote dispatch yet)"
    end
  end
end

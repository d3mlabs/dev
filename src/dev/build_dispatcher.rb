# typed: strict
# frozen_string_literal: true

require "dev/lifecycle"
require_relative "dispatch"
require_relative "dispatch_resolver"
require_relative "placement"
require_relative "target_placement"

module Dev
  # Where a build's verb executes, answered from what the composition root
  # bound at load (dev#192, K8): the build's target placement — its
  # `environment:` for the build's platform — checked buildable on this
  # machine (TargetPlacement's host half of the capability check), then
  # resolved against the host rule into a Dispatch (DispatchResolver). The
  # step `build` and `package` share between selecting the build and
  # handing their env to the dispatch; `dev help build` reads the same
  # placements for its environment column.
  #
  # The placements are those of every declared target, keyed by name. The
  # root leaves them empty when the lock could not place them at load (it
  # said why on stderr and kept the tree so the re-lock stays reachable), so a
  # verb asked to run then refuses rather than guess — the same posture as
  # ProjectCommand#placement!.
  class BuildDispatcher
    extend T::Sig

    # A build's target has no placement bound: the lock could not place it
    # at load (unreadable, or its image does not produce the platform).
    class UnboundTargetError < RuntimeError; end

    # @param placements [Hash{String => TargetPlacement}] one per declared
    #   target, as PlacementBinder#bind_targets returns them; empty when
    #   the lock was unreadable
    # @param resolver [DispatchResolver] the one decision site of native vs remote
    sig { params(placements: T::Hash[String, TargetPlacement], resolver: DispatchResolver).void }
    def initialize(placements:, resolver:)
      @placements = placements
      @resolver = resolver
    end

    # Whether the build's target has a placement bound — false only when
    # the lock could not place it at load, the state `dev help` renders
    # without an environment column.
    #
    # @param build [Lifecycle::Build]
    # @return [Boolean]
    sig { params(build: Lifecycle::Build).returns(T::Boolean) }
    def bound?(build) = @placements.key?(build.target.name)

    # Where a build is declared to run.
    #
    # @param build [Lifecycle::Build]
    # @return [Placement]
    # @raise [UnboundTargetError]
    sig { params(build: Lifecycle::Build).returns(Placement) }
    def placement_for(build) = target_placement(build).placement_for(build)

    # Whether this machine can produce the build where it is placed
    # (TargetPlacement#buildable_here?).
    #
    # @param build [Lifecycle::Build]
    # @return [Boolean]
    # @raise [UnboundTargetError]
    sig { params(build: Lifecycle::Build).returns(T::Boolean) }
    def buildable_here?(build) = target_placement(build).buildable_here?(build)

    # The dispatch a verb over +build+ hands its env to.
    #
    # @param build [Lifecycle::Build]
    # @return [Dispatch]
    # @raise [UnboundTargetError]
    # @raise [TargetPlacement::HostDoesNotProduceError] a host build of a
    #   platform this machine is not
    # @raise [DispatchResolver::RemoteDispatchUnavailableError] an image
    #   this machine was not provisioned from
    # @raise [HostRule::ContainerDriftError]
    sig { params(build: Lifecycle::Build).returns(Dispatch) }
    def dispatch_for(build)
      placement = target_placement(build)
      placement.assert_buildable_here!(build)
      @resolver.resolve(placement.placement_for(build), subject: build.name)
    end

    private

    # @param build [Lifecycle::Build]
    # @return [TargetPlacement]
    # @raise [UnboundTargetError]
    sig { params(build: Lifecycle::Build).returns(TargetPlacement) }
    def target_placement(build)
      @placements[build.target.name] || raise(UnboundTargetError,
        "`#{build}` has no environment bound: the lock could not place it at load — re-lock it (dev deps update) and retry")
    end
  end
end

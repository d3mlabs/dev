# typed: strict
# frozen_string_literal: true

require "dev/lifecycle"
require_relative "placement"
require_relative "../value_equality"

module Dev
  module Cli
    # Where one target's builds execute, as the lock answers it (dev#192,
    # K8): the target's `environment:` bound into a Placement per declared
    # platform — one entry under nil for a target with no `platforms:`. The
    # config axis never enters: an environment builds a platform, and every
    # config of it.
    #
    # Capability against placement has two halves. An image's is a
    # declaration (`target_platforms`) checked against a declaration
    # (`environment:`), true on every machine or none, so the binder refuses
    # it at load and no TargetPlacement ever holds an image that does not
    # produce its platform. The host's is this machine's platform, so it
    # holds on one machine and not another — a Mac builds the editor's macos
    # build on the host, the Linux box cannot — and a dev.yml valid on both
    # must load on both: that half is answered here, per build, when a verb
    # asks (#buildable_here?, #assert_buildable_here!) and never at load.
    #
    # The value the lifecycle verbs dispatch by and `dev help build` prints
    # the environment column from, so neither re-reads the lock.
    class TargetPlacement
      extend T::Sig
      include Dev::ValueEquality::Derived

      # A build of another target was asked for.
      class ForeignBuildError < ArgumentError; end

      # A build placed on the host asks for a platform this machine is not.
      class HostDoesNotProduceError < RuntimeError; end

      # @return [Lifecycle::Target]
      sig { returns(Lifecycle::Target) }
      attr_reader :target

      # @return [Hash{Lifecycle::Platform, nil => Placement}] one per declared
      #   platform, in declaration order; `{ nil => … }` for a platform-less target
      sig { returns(T::Hash[T.nilable(Lifecycle::Platform), Placement]) }
      attr_reader :placements

      # @return [Lifecycle::Platform] what `environment: host` produces here
      sig { returns(Lifecycle::Platform) }
      attr_reader :host_platform

      # @param target [Lifecycle::Target]
      # @param placements [Hash{Lifecycle::Platform, nil => Placement}] see #placements
      # @param host_platform [Lifecycle::Platform] this machine's platform
      sig do
        params(
          target: Lifecycle::Target,
          placements: T::Hash[T.nilable(Lifecycle::Platform), Placement],
          host_platform: Lifecycle::Platform,
        ).void
      end
      def initialize(target:, placements:, host_platform:)
        @target = target
        @placements = T.let(placements.dup.freeze, T::Hash[T.nilable(Lifecycle::Platform), Placement])
        @host_platform = host_platform
      end

      # Where one of the target's builds is declared to run.
      #
      # @param build [Lifecycle::Build] a build of #target
      # @return [Placement]
      # @raise [ForeignBuildError]
      sig { params(build: Lifecycle::Build).returns(Placement) }
      def placement_for(build)
        unless build.target == @target
          raise ForeignBuildError, "build '#{build}' is of target '#{build.target}', not '#{@target}'"
        end

        # Every platform the target declares is a key (the binder builds one
        # entry per platform), so a build of this target always resolves.
        @placements.fetch(build.platform)
      end

      # Whether this machine can produce +build+ where it is placed: always
      # in an image (the binder refused the alternative at load) and for a
      # platform-less build; on the host, only when the host is the build's
      # platform.
      #
      # @param build [Lifecycle::Build] a build of #target
      # @return [Boolean]
      # @raise [ForeignBuildError]
      sig { params(build: Lifecycle::Build).returns(T::Boolean) }
      def buildable_here?(build)
        platform = build.platform
        return true if platform.nil?

        placement = placement_for(build)
        case placement
        when Placement::Host then @host_platform == platform
        when Placement::Image then true
        else
          # simplecov:disable — the sealed placement has no third shape;
          # T.absurd keeps the static proof.
          T.absurd(placement)
          # simplecov:enable
        end
      end

      # Refuse +build+ when this machine cannot produce it, naming the fix.
      #
      # @param build [Lifecycle::Build] a build of #target
      # @return [void]
      # @raise [ForeignBuildError]
      # @raise [HostDoesNotProduceError]
      sig { params(build: Lifecycle::Build).void }
      def assert_buildable_here!(build)
        return if buildable_here?(build)

        raise HostDoesNotProduceError,
          "`#{build}` builds on the host, and this host is #{@host_platform}, which does not produce #{build.platform}; " \
            "build it on a #{build.platform} host, or name an image whose `target_platforms` has #{build.platform} " \
            "under `environment:`"
      end

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [@target, @placements, @host_platform]
      end
    end
  end
end

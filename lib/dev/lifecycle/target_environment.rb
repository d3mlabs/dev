# typed: strict
# frozen_string_literal: true

require "dev/environment_ref"
require_relative "platform"

module Dev
  module Lifecycle
    # A target's `environment:` as declared (dev#192, K8): where its builds
    # run, with the key and the two values a command uses (`<image name>`
    # or `host`, an EnvironmentRef) — one reference for every build of the
    # target, or one per declared platform (the editor builds in the Linux
    # image on linux64 and on the host on macos). A declaration, not a
    # resolution: the composition root binds each reference against the
    # lock and checks it against the build's platform (PlacementBinder).
    #
    # Sealed: a target's environment is single or per platform, nothing
    # else, so every reader is a case over two variants with a T.absurd
    # proof. A target that declares none carries nil, as a command does,
    # and takes the project's default. Which reference a given build gets,
    # and that a per-platform declaration covers exactly the target's
    # platforms, is Target's: it owns the platforms the keys are checked
    # against.
    module TargetEnvironment
      extend T::Sig
      extend T::Helpers
      # Every includer is an Object; this tells Sorbet the Object protocol
      # exists on a value typed as the interface.
      include Kernel
      abstract!
      sealed!

      # The declaration as dev.yml spelled it, for a message.
      sig { abstract.returns(String) }
      def to_s; end

      # `environment: <name>` — every build of the target, whatever its
      # platform, runs in one environment.
      class Single
        extend T::Sig
        extend T::Helpers
        include TargetEnvironment
        final!

        # @return [EnvironmentRef] the one reference
        sig(:final) { returns(EnvironmentRef) }
        attr_reader :reference

        sig(:final) { params(reference: EnvironmentRef).void }
        def initialize(reference:)
          @reference = reference
        end

        sig(:final) { override.returns(String) }
        def to_s
          @reference.to_s
        end

        sig(:final) { params(other: Object).returns(T::Boolean) }
        def ==(other)
          other.is_a?(Single) && @reference == other.reference
        end

        sig(:final) { params(other: Object).returns(T::Boolean) }
        def eql?(other)
          self == other
        end

        sig(:final) { returns(Integer) }
        def hash
          [Single, @reference].hash
        end
      end

      # `environment: { <platform>: <name>, … }` — one reference per
      # platform the target declares.
      class PerPlatform
        extend T::Sig
        extend T::Helpers
        include TargetEnvironment
        final!

        # @return [Hash{Platform => EnvironmentRef}] in declaration order
        sig(:final) { returns(T::Hash[Platform, EnvironmentRef]) }
        attr_reader :references

        sig(:final) { params(references: T::Hash[Platform, EnvironmentRef]).void }
        def initialize(references:)
          @references = T.let(references.dup.freeze, T::Hash[Platform, EnvironmentRef])
        end

        # The platforms the declaration names, in declaration order.
        #
        # @return [Array<Platform>]
        sig(:final) { returns(T::Array[Platform]) }
        def platforms
          @references.keys
        end

        sig(:final) { override.returns(String) }
        def to_s
          @references.map { |platform, reference| "#{platform}: #{reference}" }.join(", ")
        end

        sig(:final) { params(other: Object).returns(T::Boolean) }
        def ==(other)
          other.is_a?(PerPlatform) && @references == other.references
        end

        sig(:final) { params(other: Object).returns(T::Boolean) }
        def eql?(other)
          self == other
        end

        sig(:final) { returns(Integer) }
        def hash
          [PerPlatform, @references].hash
        end
      end
    end
  end
end

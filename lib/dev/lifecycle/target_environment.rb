# typed: strict
# frozen_string_literal: true

require "dev/environment_ref"
require_relative "platform"
require_relative "../value_equality"

module Dev
  module Lifecycle
    # A target's `environment:` as declared: one reference (`<image name>`
    # or `host`) for every build of the target, or one per declared
    # platform. A declaration, not a resolution: the composition root binds
    # each reference against the lock and checks it against the build's
    # platform.
    #
    # Sealed: single or per platform, nothing else. A target that declares
    # none carries nil and takes the project's default. Target owns the
    # check that a per-platform declaration covers exactly its platforms.
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
        include Dev::ValueEquality::Derived

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

        # @return [Array] the members that constitute identity
        sig(:final) { override.returns(T::Array[T.anything]) }
        def equality_members
          [@reference]
        end
      end

      # `environment: { <platform>: <name>, … }` — one reference per
      # platform the target declares.
      class PerPlatform
        extend T::Sig
        extend T::Helpers
        include TargetEnvironment
        final!
        include Dev::ValueEquality::Derived

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

        # @return [Array] the members that constitute identity
        sig(:final) { override.returns(T::Array[T.anything]) }
        def equality_members
          [@references]
        end
      end
    end
  end
end

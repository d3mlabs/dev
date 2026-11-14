# typed: strict
# frozen_string_literal: true

require "dev/environment_image"
require_relative "value_equality"

module Dev
  # What a dev.yml `environment:` key names, as the parser emits it:
  # the host, or an `image` block of dependencies.rb by name. A reference,
  # not a resolution — the parser is the dev.yml boundary and knows nothing
  # of the lock; the composition root binds every reference against the
  # lock's pins into a Placement (ProjectImages#bind) before the command
  # tree is assembled, so an unknown or ambiguous name fails at load.
  #
  # A standalone value rather than a field private to ProjectCommand: a
  # lifecycle target names its environment with the same key and the same
  # two shapes (Lifecycle::TargetEnvironment), and binds through
  # the same seam — which is why it lives in lib beside EnvironmentImage,
  # where the lifecycle vocabulary can reach it, and not in the CLI core.
  #
  # Sealed: a third shape is unrepresentable, so binding is a case over
  # two variants with a T.absurd proof.
  module EnvironmentRef
    extend T::Sig
    extend T::Helpers
    # Every includer is an Object; this tells Sorbet the Object protocol
    # exists on a value typed as the interface.
    include Kernel
    abstract!
    sealed!

    # The one value that is no image — "wherever dev itself runs"; the
    # reserved word an `image` block may not be named.
    HOST = EnvironmentImage::HOST

    class << self
      extend T::Sig

      # The dev.yml value as a reference: HOST is the host, any other name
      # is an image's. The value's shape (a non-empty string) is the
      # parser's to check; this is the one place the reserved word is read.
      #
      # @param value [String] the `environment:` value
      # @return [EnvironmentRef]
      sig { params(value: String).returns(EnvironmentRef) }
      def parse(value)
        value == HOST ? Host.new : Image.new(name: value)
      end
    end

    # The dev.yml word for this reference: what the parser read.
    sig { abstract.returns(String) }
    def to_s; end

    # `environment: host`.
    class Host
      extend T::Sig
      extend T::Helpers
      include EnvironmentRef
      final!
      include Dev::ValueEquality::Derived

      sig(:final) { override.returns(String) }
      def to_s
        HOST
      end

      # @return [Array] the members that constitute identity
      sig(:final) { override.returns(T::Array[T.anything]) }
      def equality_members
        []
      end
    end

    # `environment: <image name>` — a newtype over the name, unresolved.
    class Image
      extend T::Sig
      extend T::Helpers
      include EnvironmentRef
      final!
      include Dev::ValueEquality::Derived

      # @return [String] the `image` block's name, as written
      sig(:final) { returns(String) }
      attr_reader :name

      sig(:final) { params(name: String).void }
      def initialize(name:)
        @name = name
      end

      sig(:final) { override.returns(String) }
      def to_s
        @name
      end

      # @return [Array] the members that constitute identity
      sig(:final) { override.returns(T::Array[T.anything]) }
      def equality_members
        [@name]
      end
    end
  end
end

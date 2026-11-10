# typed: strict
# frozen_string_literal: true

require "dev/environment_image"

module Dev
  module Cli
    # Where a command's body executes, as the lock answers it: the host, or
    # one of the project's pinned images (dev#409). An EnvironmentRef bound
    # against the lock (ProjectImages#bind) — every name resolved to its
    # EnvironmentImage at load, so whoever runs or lists the command reads a
    # value and never the lock.
    #
    # The host rule's input, not its output: an Image placement says which
    # image the body belongs to; whether this machine enters a container of
    # it or runs it natively is HostRule's (ADR-0007 as amended).
    #
    # Sealed, like the reference it is bound from: CommandRunner and the
    # usage printer each case over two variants with a T.absurd proof.
    module Placement
      extend T::Sig
      extend T::Helpers
      # Every includer is an Object; this tells Sorbet the Object protocol
      # exists on a value typed as the interface.
      include Kernel
      abstract!
      sealed!

      # The environment's name as a user reads it: `host`, or the image's.
      sig { abstract.returns(String) }
      def name; end

      # The body runs wherever dev itself runs.
      class Host
        extend T::Sig
        extend T::Helpers
        include Placement
        final!

        sig(:final) { override.returns(String) }
        def name
          EnvironmentImage::HOST
        end

        sig(:final) { params(other: Object).returns(T::Boolean) }
        def ==(other)
          other.is_a?(Host)
        end

        sig(:final) { params(other: Object).returns(T::Boolean) }
        def eql?(other)
          self == other
        end

        sig(:final) { returns(Integer) }
        def hash
          [Host].hash
        end
      end

      # The body runs in a pinned image's environment.
      class Image
        extend T::Sig
        extend T::Helpers
        include Placement
        final!

        # @return [Dev::EnvironmentImage] the lock's image
        sig(:final) { returns(EnvironmentImage) }
        attr_reader :image

        sig(:final) { params(image: EnvironmentImage).void }
        def initialize(image:)
          @image = image
        end

        sig(:final) { override.returns(String) }
        def name
          @image.name
        end

        # Two placements of one image are equal by the image's identity (its
        # digest): the lock pins one image per name.
        sig(:final) { params(other: Object).returns(T::Boolean) }
        def ==(other)
          other.is_a?(Image) && @image.name == other.image.name && @image.digest == other.image.digest
        end

        sig(:final) { params(other: Object).returns(T::Boolean) }
        def eql?(other)
          self == other
        end

        sig(:final) { returns(Integer) }
        def hash
          [Image, @image.name, @image.digest].hash
        end
      end
    end
  end
end

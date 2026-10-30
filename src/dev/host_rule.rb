# typed: strict
# frozen_string_literal: true

require "dev/environment_image"
require "dev/host_environment"
require "dev/project_images"

module Dev
  # Does an image's work run on this machine, or in a container of the
  # image? One answer for the two callers that ask it — CommandRunner
  # placing a command, `dev container up` deciding what to bring up — and
  # one rule: native exactly when this host was provisioned from the
  # image — its `/etc/dev/environment` marker names the image at the
  # lock's digest (HostEnvironment; the host rule, dev#308, ADR-0007
  # amended). A bare host, a Mac, a host baked from an older recipe all
  # fail it and run inside; dev never converges a host's OS toward the
  # lock.
  #
  # Inside a container the same marker is the container's own, and a
  # mismatch is not a fallback but an error: the container cannot replace
  # itself (assert_container_is!, assert_container_current!).
  class HostRule
    extend T::Sig

    # dev runs inside a container whose image is not the one the lock
    # pins for this work — re-create it from the host.
    class ContainerDriftError < RuntimeError; end

    # @param host_environment [Dev::HostEnvironment] what this machine was provisioned from
    sig { params(host_environment: HostEnvironment).void }
    def initialize(host_environment: HostEnvironment.new)
      @host_environment = host_environment
    end

    # What this machine was provisioned from, for a report line
    # (`name@<12 hex>`, or what is missing).
    #
    # @return [String]
    sig { returns(String) }
    def host = @host_environment.describe

    # Whether +image+'s work runs on this host (no container).
    #
    # @param image [Dev::EnvironmentImage]
    # @return [Boolean]
    sig { params(image: EnvironmentImage).returns(T::Boolean) }
    def native?(image)
      @host_environment.provisioned_from?(image)
    end

    # The reason native? held, for a report line.
    #
    # @param image [Dev::EnvironmentImage] one native? is true of
    # @return [String]
    sig { params(image: EnvironmentImage).returns(String) }
    def why_native(image)
      "this host was provisioned from #{@host_environment.describe}"
    end

    # Whether this host was provisioned from +image+ under another digest:
    # the marker names it, the lock moved on. An absent marker or another
    # image's is not drift.
    #
    # @param image [Dev::EnvironmentImage]
    # @return [Boolean]
    sig { params(image: EnvironmentImage).returns(T::Boolean) }
    def drifted?(image)
      @host_environment.name == image.name && !@host_environment.provisioned_from?(image)
    end

    # Inside a container: refuse +image+'s work unless this container is
    # that image at the lock's digest.
    #
    # @param image [Dev::EnvironmentImage] the work's image
    # @return [void]
    # @raise [ContainerDriftError]
    sig { params(image: EnvironmentImage).void }
    def assert_container_is!(image)
      return if @host_environment.provisioned_from?(image)

      raise ContainerDriftError, drift_message(image)
    end

    # Inside a container at provisioning time: the pin this container was
    # made from must carry the marker's digest. A marker naming no pin
    # (another project's container) asserts nothing.
    #
    # @param pins [Array<Dev::EnvironmentImage>] the lock's images
    # @return [void]
    # @raise [ContainerDriftError]
    sig { params(pins: T::Array[EnvironmentImage]).void }
    def assert_container_current!(pins)
      own = pins.find { |pin| pin.name == @host_environment.name }
      assert_container_is!(own) if own
    end

    private

    # @param image [Dev::EnvironmentImage]
    # @return [String]
    sig { params(image: EnvironmentImage).returns(String) }
    def drift_message(image)
      "this container is #{@host_environment.describe}; the lock's #{image.name} is " \
        "#{image.name}@#{image.short_digest} — re-create it from the host: `dev container reset && dev up`"
    end
  end
end

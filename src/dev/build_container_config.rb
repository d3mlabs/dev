# typed: strict
# frozen_string_literal: true

module Dev
  # Value object for the build.container block in dev.yml.
  #
  # When present, commands run inside a Docker container by default.
  # Content-addressed image tags are computed from Dockerfile + build-deps.lock.
  #
  # dev.yml example:
  #   build:
  #     container:
  #       image: snappy-linux
  #       registry: jpduchesne89
  #       volumes:
  #         - "~/.dev/engines/unreal-engine-css:/ue"
  #       build_args:
  #         WWISE_EMAIL: wwise/email
  #         WWISE_PASSWORD: wwise/password
  #
  # build_args maps docker --build-arg names to Dev::Credentials
  # "namespace/key" references, resolved only when the image is built.
  class BuildContainerConfig
    extend T::Sig

    sig { returns(String) }
    attr_reader :image

    sig { returns(String) }
    attr_reader :registry

    sig { returns(T::Array[String]) }
    attr_reader :volumes

    sig { returns(T::Hash[String, String]) }
    attr_reader :build_args

    sig do
      params(
        image: String,
        registry: String,
        volumes: T::Array[String],
        build_args: T::Hash[String, String],
      ).void
    end
    def initialize(image:, registry:, volumes: [], build_args: {})
      @image = T.let(image, String)
      @registry = T.let(registry, String)
      @volumes = T.let(volumes, T::Array[String])
      @build_args = T.let(build_args, T::Hash[String, String])
    end

    # Full image reference without tag (e.g. "jpduchesne89/snappy-linux").
    sig { returns(String) }
    def image_ref
      "#{@registry}/#{@image}"
    end

    sig { params(other: Object).returns(T::Boolean) }
    def ==(other)
      return false unless other.is_a?(BuildContainerConfig)

      @image == other.image && @registry == other.registry &&
        @volumes == other.volumes && @build_args == other.build_args
    end

    sig { params(other: Object).returns(T::Boolean) }
    def eql?(other)
      self == other
    end

    sig { returns(Integer) }
    def hash
      [@image, @registry, @volumes, @build_args].hash
    end
  end
end

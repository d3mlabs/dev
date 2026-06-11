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
  class BuildContainerConfig
    extend T::Sig

    sig { returns(String) }
    attr_reader :image

    sig { returns(String) }
    attr_reader :registry

    sig { params(image: String, registry: String).void }
    def initialize(image:, registry:)
      @image = T.let(image, String)
      @registry = T.let(registry, String)
    end

    # Full image reference without tag (e.g. "jpduchesne89/snappy-linux").
    sig { returns(String) }
    def image_ref
      "#{@registry}/#{@image}"
    end

    sig { params(other: Object).returns(T::Boolean) }
    def ==(other)
      return false unless other.is_a?(BuildContainerConfig)

      @image == other.image && @registry == other.registry
    end

    sig { params(other: Object).returns(T::Boolean) }
    def eql?(other)
      self == other
    end

    sig { returns(Integer) }
    def hash
      [@image, @registry].hash
    end
  end
end

# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/build_container"
require "dev/build_container_config"
require "dev/credentials"
require "dev/deps/lockfile"
require "dev/engine_resources"
require "dev/environment_image"

module Dev
  # Which image a project's containerized commands run in, and the one way
  # to make it ready: the lock's `image` pin (dev#277, `EnvironmentImage`),
  # or — until d3mlabs/dev#311 — the hand-written Dockerfile the
  # `build.container.image/registry` block names. Both ServiceUp and the
  # CommandRunner resolve through here, so the two paths are chosen in one
  # place and the deprecated one is retired by deleting one branch.
  class ProjectImage
    extend T::Sig

    # The project declares no image: no `image` pin in its lock and no
    # Dockerfile image in its container block.
    class NoEnvironmentImageError < StandardError; end

    # The lock holds several `image` pins and nothing yet says which a
    # command runs in (d3mlabs/dev#307).
    class AmbiguousEnvironmentImageError < StandardError; end

    IGNORED_DOCKERFILE_IMAGE =
      "dev: build.container.image/registry are ignored — the project's image is its lock's `image` pin; " \
      "delete them from dev.yml (the Dockerfile path goes with d3mlabs/dev#311)"

    # @param root [Pathname] the checkout (its deps.lock is read)
    # @param config [Dev::BuildContainerConfig, nil] the `build.container` block
    # @param engine [Dev::EngineResources::Hint, nil] the project's engine
    #   floor, measured before any image work
    sig do
      params(
        root: Pathname,
        config: T.nilable(Dev::BuildContainerConfig),
        engine: T.nilable(Dev::EngineResources::Hint),
      ).void
    end
    def initialize(root:, config:, engine: nil)
      @root = root
      @config = config
      @engine = engine
    end

    # The lock's image, when the project has one.
    #
    # @return [Dev::EnvironmentImage, nil] nil on the deprecated path: no
    #   pin, and the container block names a Dockerfile image
    # @raise [NoEnvironmentImageError] no pin and no Dockerfile image
    # @raise [AmbiguousEnvironmentImageError] several pins
    # @raise [EnvironmentImage::StaleDigestError] the pin was locked by another dev
    sig { returns(T.nilable(Dev::EnvironmentImage)) }
    def environment_image
      pins = Deps::Lockfile.new(dir: @root).read.select { |pin| pin.integration == :image }
      case pins.size
      when 0
        return nil if dockerfile_image?

        raise NoEnvironmentImageError,
          "#{@root} declares no image: add an `image` block to dependencies.rb and run: dev deps update"
      when 1
        $stderr.puts IGNORED_DOCKERFILE_IMAGE if dockerfile_image?
        EnvironmentImage.from_pin(T.must(pins.first))
      else
        raise AmbiguousEnvironmentImageError,
          "#{@root} locks several images (#{pins.map(&:name).join(", ")}) and commands cannot yet name theirs — " \
            "d3mlabs/dev#307"
      end
    end

    # The image's reference, with no engine and no network — what
    # `dev container status|tag` print.
    #
    # @return [String]
    sig { returns(String) }
    def ref
      image = environment_image
      return image.ref if image

      BuildContainer.image_with_tag(T.must(@config), project_root: @root)
    end

    # Make the image ready on the client's engine: the pin through
    # `ensure_environment_image!`, the deprecated Dockerfile through
    # `ensure_image!` (its credentials resolved lazily, only on a build).
    #
    # @param client [Dev::BuildContainer]
    # @param publish [Boolean] the publisher designation (DEV_PUBLISH_IMAGE=1)
    # @return [String] the ready image's reference
    sig { params(client: Dev::BuildContainer, publish: T::Boolean).returns(String) }
    def ensure!(client:, publish:)
      image = environment_image
      return client.ensure_environment_image!(image, publish:, resources: @engine) if image

      config = T.must(@config)
      client.ensure_image!(
        config,
        project_root: @root,
        push: false,
        publish:,
        build_args_provider: -> { Credentials.resolve_build_args(config.build_args) },
        secrets_provider: -> { Credentials.resolve_build_args(config.build_secrets) },
        resources: @engine,
      )
    end

    private

    # @return [Boolean] whether the container block names a Dockerfile image
    sig { returns(T::Boolean) }
    def dockerfile_image?
      @config&.dockerfile_image? || false
    end
  end
end

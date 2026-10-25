# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/build_container"
require "dev/build_container_config"
require "dev/credentials"
require "dev/engine_resources"
require "dev/environment_platform"

module Dev
  # Deprecated (d3mlabs/dev#311): the hand-written-Dockerfile image a
  # `build.container.image/registry` block names, wearing the readers an
  # EnvironmentImage has — name, ref, the container's shape, the platform —
  # so the layers that place and run a command see one kind of image until
  # the consumers have migrated. Deleted with the legacy path.
  class DockerfileImage
    extend T::Sig

    # @param root [Pathname] the checkout (its Dockerfile, its content tag)
    # @param config [Dev::BuildContainerConfig] a block naming an image
    sig { params(root: Pathname, config: Dev::BuildContainerConfig).void }
    def initialize(root:, config:)
      @root = root
      @config = config
    end

    # @return [String] the block's `image`
    sig { returns(String) }
    def name = T.must(@config.image)

    # @return [Boolean] the block's `persist`
    sig { returns(T::Boolean) }
    def persist = @config.persist

    # @return [Array<String>] the block's `volumes`
    sig { returns(T::Array[String]) }
    def volumes = @config.volumes

    # @return [Hash{String => String}] the block's `run_env`
    sig { returns(T::Hash[String, String]) }
    def run_env = @config.run_env

    # @return [String] the content-addressed reference, computed from the checkout
    sig { returns(String) }
    def ref = BuildContainer.image_with_tag(@config, project_root: @root)

    # @return [String, nil] the Dockerfile's first `FROM --platform`, as
    #   dev's key; nil when it declares none (the host is then never taken
    #   for the environment)
    sig { returns(T.nilable(String)) }
    def dev_platform = EnvironmentPlatform.from_dockerfile(@root)

    # Make the image ready on the client's engine through the Dockerfile
    # path, its credentials resolved lazily — only on a build.
    #
    # @param client [Dev::BuildContainer]
    # @param publish [Boolean] the publisher designation (DEV_PUBLISH_IMAGE=1)
    # @param resources [Dev::EngineResources::Hint, nil] the project's engine floor
    # @return [String] the ready image's reference
    sig do
      params(client: Dev::BuildContainer, publish: T::Boolean, resources: T.nilable(Dev::EngineResources::Hint))
        .returns(String)
    end
    def ensure!(client:, publish:, resources:)
      config = @config
      client.ensure_image!(
        config,
        project_root: @root,
        push: false,
        publish:,
        build_args_provider: -> { Credentials.resolve_build_args(config.build_args) },
        secrets_provider: -> { Credentials.resolve_build_args(config.build_secrets) },
        resources:,
      )
    end
  end
end

# typed: strict
# frozen_string_literal: true

require "pathname"
require "sorbet-runtime"
require "dev/build_container"
require "dev/container_engine"
require "dev/container_github_token"
require "dev/credentials"
require "dev/engine_resources"
require "dev/engine_resources_check"
require "dev/environment_image"
require "dev/lifecycle/workspace"

module Dev
  # The project's build container as the build host it is: where a
  # command or a lifecycle verb runs when it leaves this
  # machine for a container of the project's image. One way in, for every
  # caller — a `docker exec` (a persisted image's service container, or a
  # named one `dev up` is provisioning) or a one-shot `docker run --rm`
  # — over the workspace the transport delivered (Lifecycle::Workspace):
  # the checkout itself, bind-mounted at its own path (BuildContainer),
  # where the command runs as the process. The container's verdict is the
  # process's exit status, returned, not interpreted: each caller knows
  # what a nonzero means for it.
  #
  # What rides in: the image's resolved `run_env` (best-effort, so a
  # missing runtime secret never blocks a command that does not need it)
  # and the host's gh token as GH_TOKEN unless the run_env named one
  # (ContainerGithubToken) — whatever calls `gh` inside has the auth the
  # host holds. Names on argv, values in the spawn env.
  #
  # The engine-floor gate (EngineResourcesCheck) is this path's
  # own: the project's `engine:` hint is measured against the engine once,
  # before the image is reached for. `dev up` has its own owner
  # (EngineProvisioner) and measures after sizing; neither path reads
  # `docker info` twice.
  class ProjectContainer
    extend T::Sig

    # The engine does not answer: nothing can run in a container until
    # `dev up` brings it up.
    class EngineUnavailableError < RuntimeError; end

    # The workspace handed in is not the mounted checkout — another
    # transport's delivery, which this container has no way to run in.
    class WorkspaceNotMountedError < ArgumentError; end

    # @param project_root [Pathname] the checkout the container works for
    # @param client [BuildContainer, nil] the engine-injected docker
    #   operations; resolved lazily for the invoking user when not injected,
    #   so a run that never touches a container never reads the engine record
    # @param engine_hint [EngineResources::Hint, nil] the project's engine floor
    # @param resources_check [EngineResourcesCheck] the engine-vs-hint gate
    # @param github_token [ContainerGithubToken] the host's gh token, as GH_TOKEN inside
    sig do
      params(
        project_root: Pathname,
        client: T.nilable(BuildContainer),
        engine_hint: T.nilable(EngineResources::Hint),
        resources_check: EngineResourcesCheck,
        github_token: ContainerGithubToken,
      ).void
    end
    def initialize(project_root:, client: nil, engine_hint: nil, resources_check: EngineResourcesCheck.new,
                   github_token: ContainerGithubToken.new)
      @project_root = project_root
      @client = client
      @engine_hint = engine_hint
      @resources_check = resources_check
      @github_token = github_token
    end

    # Where a command or verb is going, for the crossing line.
    #
    # @param image [EnvironmentImage]
    # @return [String]
    sig { params(image: EnvironmentImage).returns(String) }
    def destination(image)
      "in #{image.name} (container)"
    end

    # Refuse before anything is run when the engine is not up.
    #
    # @return [void]
    # @raise [EngineUnavailableError]
    sig { void }
    def assert_engine_up!
      return unless client.engine.resources.nil?

      raise EngineUnavailableError, "the container engine does not answer; `dev up` brings it up"
    end

    # Run a command in a container of the image over the workspace: the
    # persisted image's service container (created or restarted warm), a
    # one-shot container otherwise.
    #
    # @param image [EnvironmentImage] the command's environment
    # @param argv [Array<String>] the command, run in the workspace
    # @param workspace [Lifecycle::Workspace] what the container holds of the tree
    # @return [Integer] the container process's exit status
    # @raise [EngineResourcesCheck::UndersizedEngineError] when the engine falls short of the project's floor
    # @raise [WorkspaceNotMountedError]
    sig { params(image: EnvironmentImage, argv: T::Array[String], workspace: Lifecycle::Workspace).returns(Integer) }
    def run(image, argv:, workspace:)
      checkout = mounted_path(workspace)
      @resources_check.check!(engine: client.engine, hint: @engine_hint)
      image_tag = client.ensure_environment_image!(image, publish: publish_image?)
      invocation = if image.persist
        container = client.ensure_service!(image_tag, project_root: checkout, volumes: image.volumes)
        client.docker_exec_command(container, project_root: checkout, argv:, env: run_env(image))
      else
        client.docker_run_command(image_tag, project_root: checkout, argv:, volumes: image.volumes, env: run_env(image))
      end
      client.execute(invocation)
    end

    # Run a command in a running container the caller already holds (the
    # one `dev up` is provisioning), over the workspace.
    #
    # @param container [String] the running container's name
    # @param image [EnvironmentImage] the container's image, whose `run_env` rides in
    # @param argv [Array<String>] the command, run in the workspace
    # @param workspace [Lifecycle::Workspace] what the container holds of the tree
    # @return [Integer] the container process's exit status
    # @raise [WorkspaceNotMountedError]
    sig do
      params(container: String, image: EnvironmentImage, argv: T::Array[String], workspace: Lifecycle::Workspace).returns(Integer)
    end
    def exec_in(container, image:, argv:, workspace:)
      checkout = mounted_path(workspace)
      client.execute(client.docker_exec_command(container, project_root: checkout, argv:, env: run_env(image)))
    end

    # Bring a directory of the container's store to the host's — what
    # `--fetch` asks for. A no-op when the two stores are one (a Linux
    # host's data root bind-mounted); a `docker cp` out of a
    # one-shot container of the image otherwise.
    #
    # @param image [EnvironmentImage]
    # @param into [Pathname] the host's directory for it, under the host's data root
    # @return [void]
    # @raise [BuildContainer::OutsideDataRootError] when `into` is not under the data root
    # @raise [BuildContainer::CopyOutFailedError]
    sig { params(image: EnvironmentImage, into: Pathname).void }
    def fetch(image, into:)
      return if client.data_root_shared?

      image_tag = client.ensure_environment_image!(image, publish: false)
      client.with_one_shot_container(image_tag, project_root: @project_root) do |container|
        client.copy_out(container, from: client.inside_path(into), into:)
      end
    end

    private

    # The engine-injected docker operations, constructed at this seam.
    #
    # @return [BuildContainer]
    sig { returns(BuildContainer) }
    def client
      @client ||= BuildContainer.new(engine: ContainerEngine.resolve)
    end

    # The checkout the workspace mounts: the one shape this container runs
    # in, read back from the sealed type in one place.
    #
    # @param workspace [Lifecycle::Workspace]
    # @return [Pathname] the checkout's path, the same inside
    # @raise [WorkspaceNotMountedError] for a workspace another transport delivered
    sig { params(workspace: Lifecycle::Workspace).returns(Pathname) }
    def mounted_path(workspace)
      case workspace
      when Lifecycle::Workspace::Mounted
        workspace.path
      when Lifecycle::Workspace::Snapshot
        raise WorkspaceNotMountedError,
          "the container runs in the mounted checkout, not #{workspace.description}: a snapshot branch is a runner's delivery"
      else
        T.absurd(workspace)
      end
    end

    # @param image [EnvironmentImage]
    # @return [Hash{String => String}] the resolved run_env, then the host's gh token unless named
    sig { params(image: EnvironmentImage).returns(T::Hash[String, String]) }
    def run_env(image)
      @github_token.merge_into(Credentials.resolve_run_env(image.run_env))
    end

    # Whether the resolved image should be published to the shared
    # registry. Off by default — a normal local run must never push. The
    # provisioning step (e.g. CI's `dev up`) opts in by setting
    # DEV_PUBLISH_IMAGE, so it populates the registry that every other
    # machine — and a from-scratch CI runner — pulls from. Gated by an env
    # var rather than the command name so any project's provisioning can
    # enable it without dev hard-coding which command is the publisher.
    #
    # @return [Boolean]
    sig { returns(T::Boolean) }
    def publish_image?
      ENV["DEV_PUBLISH_IMAGE"] == "1"
    end
  end
end

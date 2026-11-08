# typed: strict
# frozen_string_literal: true

require "pathname"
require "sorbet-runtime"
require "dev/build_container"
require "dev/container_engine"
require "dev/container_github_token"
require "dev/container_workspace"
require "dev/credentials"
require "dev/engine_resources"
require "dev/engine_resources_check"
require "dev/environment_image"
require "dev/lifecycle/gh"
require "dev/lifecycle/snapshot"

module Dev
  # The project's build container as the build host it is (ADR-0008,
  # dev#421): where a command or a lifecycle verb runs when it leaves this
  # machine for a container of the project's image. One way in, for every
  # caller — a `docker exec` (a persisted image's service container, or a
  # named one `dev up` is provisioning) or a one-shot `docker run --rm`
  # — and the same program inside: the container brings its workspace to
  # the snapshot it is handed and runs the command there
  # (ContainerWorkspace). The container's verdict is the process's exit
  # status, returned, not interpreted: each caller knows what a nonzero
  # means for it.
  #
  # What rides in: the image's resolved `run_env` (best-effort, so a
  # missing runtime secret never blocks a command that does not need it)
  # and the host's gh token as GH_TOKEN unless the run_env named one
  # (ContainerGithubToken) — the fetch and whatever calls `gh` inside have
  # the auth the host holds. Names on argv, values in the spawn env
  # (dev#317).
  #
  # The engine-floor gate (EngineResourcesCheck, dev#400) is this path's
  # own: the project's `engine:` hint is measured against the engine once,
  # before the image is reached for. `dev up` has its own owner
  # (EngineProvisioner) and measures after sizing; neither path reads
  # `docker info` twice.
  class ProjectContainer
    extend T::Sig

    # The engine does not answer: nothing can run in a container until
    # `dev up` brings it up.
    class EngineUnavailableError < RuntimeError; end

    # gh named no repo for the checkout (no `origin`, not a GitHub
    # remote): the container has nowhere to fetch the snapshot from.
    class RepoUnresolvedError < RuntimeError; end

    # The gh query for the checkout's `owner/repo`.
    REPO_QUERY = T.let(%w[repo view --json nameWithOwner -q .nameWithOwner].freeze, T::Array[String])

    class << self
      extend T::Sig

      # The repo resolver a caller gets by default: gh in the checkout,
      # asked when called — never at construction, so `dev help` pays no
      # gh call.
      #
      # @param project_root [Pathname]
      # @return [Proc] `-> { "owner/repo\n" }`
      sig { params(project_root: Pathname).returns(T.proc.returns(String)) }
      def default_repo_resolver(project_root)
        -> { Lifecycle::Gh.new(root: project_root).capture(REPO_QUERY) }
      end
    end

    # @param project_root [Pathname] the checkout the container works for
    # @param client [BuildContainer, nil] the engine-injected docker
    #   operations; resolved lazily for the invoking user when not injected,
    #   so a run that never touches a container never reads the engine record
    # @param engine_hint [EngineResources::Hint, nil] the project's engine floor
    # @param resources_check [EngineResourcesCheck] the engine-vs-hint gate
    # @param github_token [ContainerGithubToken] the host's gh token, as GH_TOKEN inside
    # @param repo_resolver [Proc] the checkout's repo as the forge spells it
    #   (`owner/repo`) — `gh repo view` in the checkout; called once, on the
    #   first run, never at construction (a gh call at load would tax `dev help`)
    sig do
      params(
        project_root: Pathname,
        client: T.nilable(BuildContainer),
        engine_hint: T.nilable(EngineResources::Hint),
        resources_check: EngineResourcesCheck,
        github_token: ContainerGithubToken,
        repo_resolver: T.proc.returns(String),
      ).void
    end
    def initialize(project_root:, client: nil, engine_hint: nil, resources_check: EngineResourcesCheck.new,
                   github_token: ContainerGithubToken.new,
                   repo_resolver: ProjectContainer.default_repo_resolver(project_root))
      @project_root = project_root
      @client = client
      @engine_hint = engine_hint
      @resources_check = resources_check
      @github_token = github_token
      @repo_resolver = repo_resolver
      @repo = T.let(nil, T.nilable(String))
      @workspace = T.let(nil, T.nilable(ContainerWorkspace))
    end

    # Where a command or verb is going, for the crossing line.
    #
    # @param image [EnvironmentImage]
    # @return [String]
    sig { params(image: EnvironmentImage).returns(String) }
    def destination(image) = "in #{image.name} (container)"

    # Refuse before anything is pushed when the engine is not up.
    #
    # @return [void]
    # @raise [EngineUnavailableError]
    sig { void }
    def assert_engine_up!
      return unless client.engine.resources.nil?

      raise EngineUnavailableError, "the container engine does not answer; `dev up` brings it up"
    end

    # Run a command in a container of the image at the snapshot: the
    # persisted image's service container (created or restarted warm), a
    # one-shot container otherwise.
    #
    # @param image [EnvironmentImage] the command's environment
    # @param argv [Array<String>] the command, run in the workspace
    # @param snapshot [Lifecycle::Snapshot] the pushed tree the workspace is brought to
    # @return [Integer] the container process's exit status
    # @raise [EngineResourcesCheck::UndersizedEngineError] when the engine falls short of the project's floor
    # @raise [RepoUnresolvedError]
    sig { params(image: EnvironmentImage, argv: T::Array[String], snapshot: Lifecycle::Snapshot).returns(Integer) }
    def run(image, argv:, snapshot:)
      @resources_check.check!(engine: client.engine, hint: @engine_hint)
      image_tag = client.ensure_environment_image!(image, publish: publish_image?)
      shell_cmd = workspace.script(snapshot:, repo:, argv:)
      invocation = if image.persist
        container = client.ensure_service!(image_tag, project_root: @project_root, volumes: image.volumes)
        client.docker_exec_command(container, shell_cmd:, env: run_env(image))
      else
        client.docker_run_command(image_tag, project_root: @project_root, shell_cmd:, volumes: image.volumes, env: run_env(image))
      end
      client.execute(invocation)
    end

    # Run a command in a running container the caller already holds (the
    # one `dev up` is provisioning), at the snapshot.
    #
    # @param container [String] the running container's name
    # @param image [EnvironmentImage] the container's image, whose `run_env` rides in
    # @param argv [Array<String>] the command, run in the workspace
    # @param snapshot [Lifecycle::Snapshot]
    # @return [Integer] the container process's exit status
    # @raise [RepoUnresolvedError]
    sig do
      params(container: String, image: EnvironmentImage, argv: T::Array[String], snapshot: Lifecycle::Snapshot).returns(Integer)
    end
    def exec_in(container, image:, argv:, snapshot:)
      shell_cmd = workspace.script(snapshot:, repo:, argv:)
      client.execute(client.docker_exec_command(container, shell_cmd:, env: run_env(image)))
    end

    # Bring a directory of the container's store to the host's — what
    # `--fetch` asks for. A no-op when the two stores are one (a Linux
    # host's data root bind-mounted, dev#308); a `docker cp` out of a
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

    # The engine-injected docker operations, constructed at this seam (the
    # composition point plans#26 names).
    #
    # @return [BuildContainer]
    sig { returns(BuildContainer) }
    def client
      @client ||= BuildContainer.new(engine: ContainerEngine.resolve)
    end

    # @return [ContainerWorkspace] the container's checkout, under its data root
    sig { returns(ContainerWorkspace) }
    def workspace
      @workspace ||= ContainerWorkspace.new(project_root: @project_root, data_root: client.data_root_mount)
    end

    # @return [String] `owner/repo`
    # @raise [RepoUnresolvedError]
    # @raise [Lifecycle::Gh::CommandFailedError]
    sig { returns(String) }
    def repo
      @repo ||= begin
        resolved = @repo_resolver.call.strip
        raise RepoUnresolvedError, "gh named no repo for #{@project_root}; the container fetches the snapshot from the checkout's GitHub remote" if resolved.empty?

        resolved
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

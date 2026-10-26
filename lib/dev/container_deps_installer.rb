# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require "dev/container_engine"
require "dev/container_github_token"

module Dev
  # Runs the project's dependency install inside its persistent build
  # container: `dev deps install`, as the container's own dev, at the project
  # mount. The container is a build host with its own data root (ADR-0008),
  # so this is the install of the whole linux lock — toolchain, gh trees,
  # gems — into the container's volumes. The run_env is injected for the
  # integrations that need a credential at install time, and the host's gh
  # token rides along as GH_TOKEN (ContainerGithubToken): the private
  # releases the container now fetches for itself need the auth the host
  # already holds.
  class ContainerDepsInstaller
    extend T::Sig

    PROJECT_MOUNT = "/project"

    # The env var gh reads its token from, inside.
    GH_TOKEN = ContainerGithubToken::GH_TOKEN

    # The in-container install exited nonzero.
    class InstallFailedError < StandardError
      extend T::Sig

      # @param container [String] the container name
      sig { params(container: String).void }
      def initialize(container:)
        super("dev: dev deps install failed inside #{container}")
      end
    end

    # The host's gh token, or nil when gh is not logged in.
    HOST_GH_TOKEN = ContainerGithubToken::HOST

    # @param engine [ContainerEngine] the engine the container runs under
    # @param github_token [Proc] answers the host's gh token (nil or empty
    #   when there is none); injected so tests never shell out to gh
    sig { params(engine: ContainerEngine, github_token: T.proc.returns(T.nilable(String))).void }
    def initialize(engine:, github_token: HOST_GH_TOKEN)
      @engine = engine
      @github_token = T.let(ContainerGithubToken.new(source: github_token), ContainerGithubToken)
    end

    # Install the project's dependencies in +container+.
    #
    # @param container [String] the container name
    # @param env [Hash{String => String}] env vars to inject (the resolved
    #   run_env); a GH_TOKEN it names wins over the host's
    # @return [void]
    # @raise [InstallFailedError] when the install exits nonzero
    sig { params(container: String, env: T::Hash[String, String]).void }
    def install!(container, env:)
      env_flags = @github_token.merge_into(env).flat_map { |name, value| ["-e", "#{name}=#{value}"] }
      installed = @engine.run(["exec", *env_flags, "-w", PROJECT_MOUNT, container, "dev", "deps", "install"])
      raise InstallFailedError.new(container:) unless installed
    end
  end
end

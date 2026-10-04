# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require "dev/container_engine"

module Dev
  # Runs the project's dependency install inside its persistent build
  # container: `dev deps install`, as the container's own dev, at the project
  # mount. Inside, the builtin takes its container side (Registry's scope
  # axis) against the store Ruby, so this is how the gems and brew deps a
  # containerized command consumes get there. The run_env is injected for
  # the integrations that need a credential at install time.
  class ContainerDepsInstaller
    extend T::Sig

    PROJECT_MOUNT = "/project"

    # The in-container install exited nonzero.
    class InstallFailedError < StandardError
      extend T::Sig

      # @param container [String] the container name
      sig { params(container: String).void }
      def initialize(container:)
        super("dev: dev deps install failed inside #{container}")
      end
    end

    # @param engine [ContainerEngine] the engine the container runs under
    sig { params(engine: ContainerEngine).void }
    def initialize(engine:)
      @engine = engine
    end

    # Install the project's container-side dependencies in +container+.
    #
    # @param container [String] the container name
    # @param env [Hash{String => String}] env vars to inject (the resolved run_env)
    # @return [void]
    # @raise [InstallFailedError] when the install exits nonzero
    sig { params(container: String, env: T::Hash[String, String]).void }
    def install!(container, env:)
      env_flags = env.flat_map { |name, value| ["-e", "#{name}=#{value}"] }
      installed = @engine.run(["exec", *env_flags, "-w", PROJECT_MOUNT, container, "dev", "deps", "install"])
      raise InstallFailedError.new(container:) unless installed
    end
  end
end

# typed: strict
# frozen_string_literal: true

require "dev/container_engine"

module Dev
  # Per-user provisioning for the Docker Desktop engine: verify-only. Docker
  # Desktop is a user-managed GUI app — dev never installs or starts it, it
  # just proves the daemon answers through the resolved engine so a
  # provisioning flow (e.g. `dev runner register`'s bootstrap) fails loud and
  # early instead of at the first build.
  class DockerDesktopProvisioner
    extend T::Sig

    # `docker info` did not answer through the resolved engine — the daemon
    # is not running (or DOCKER_HOST points somewhere dead).
    class EngineUnreachableError < RuntimeError; end

    # @param engine [Dev::ContainerEngine] the invoking user's resolved engine
    sig { params(engine: Dev::ContainerEngine).void }
    def initialize(engine:)
      @engine = engine
    end

    # Prove the daemon answers. Idempotent by nature (a read-only probe).
    #
    # @return [void]
    # @raise [EngineUnreachableError] when the daemon does not answer
    sig { void }
    def provision!
      return if @engine.run(["info"], out: File::NULL, err: File::NULL)

      raise EngineUnreachableError,
        "the docker daemon did not answer (engine: #{@engine.kind}) — start Docker Desktop " \
        "(or fix DOCKER_HOST) and retry."
    end
  end
end

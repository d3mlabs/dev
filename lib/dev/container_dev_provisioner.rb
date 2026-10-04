# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/container_engine"
require "dev/version"

module Dev
  # Keeps a build container's dev at the host's exact version — "containers
  # match the orchestrator" (README, "dev is live infrastructure").
  #
  # Compare-and-install with a no-op steady state: `dev version` inside the
  # container is probed through `docker exec`; when it differs from the
  # host's (or there is no dev at all — a fresh container, an image whose
  # bootstrap removed dev-core), bin/container-provision-dev.sh installs the
  # host's version from the tap's history into the container's writable
  # layer. The host is the only writer of the container's dev; the inside dev
  # (DEV_INSIDE_CONTAINER) never self-updates.
  class ContainerDevProvisioner
    extend T::Sig

    # The install script, shipped beside dev's bin so a formula install
    # carries it; its text travels to the container as the `sh -c` argument.
    SCRIPT = T.let(Pathname.new(File.expand_path("../../bin/container-provision-dev.sh", __dir__)), Pathname)

    # Raised when the in-container install exits nonzero.
    class ProvisionFailedError < StandardError
      extend T::Sig

      # @param container [String] the container name
      # @param version [String] the version that failed to install
      sig { params(container: String, version: String).void }
      def initialize(container:, version:)
        super("installing dev-core #{version} into #{container} failed — see the output above; " \
          "the container's image must carry Linuxbrew with the d3mlabs/d3mlabs tap")
      end
    end

    sig { returns(String) }
    attr_reader :host_version

    # @param engine [Dev::ContainerEngine] the engine the container runs on
    # @param host_version [String] the version to converge the container to
    sig { params(engine: Dev::ContainerEngine, host_version: String).void }
    def initialize(engine:, host_version: Dev::Version.current)
      @engine = engine
      @host_version = host_version
    end

    # Converge the container's dev to the host's version.
    #
    # @param container [String] a running container's name
    # @return [Symbol] :current when nothing was done, :installed after an install
    # @raise [ProvisionFailedError] when the install fails
    sig { params(container: String).returns(Symbol) }
    def provision!(container)
      return :current if installed_version(container) == @host_version

      installed = @engine.run(["exec", container, "sh", "-c", SCRIPT.read, "sh", @host_version])
      raise ProvisionFailedError.new(container:, version: @host_version) unless installed

      :installed
    end

    private

    # What the container's dev reports, or nil when the probe fails (no dev,
    # or a dev too old to know `version`).
    #
    # @param container [String]
    # @return [String, nil]
    sig { params(container: String).returns(T.nilable(String)) }
    def installed_version(container)
      reported = @engine.capture(["exec", container, "dev", "version"]).strip
      reported.empty? ? nil : reported
    end
  end
end

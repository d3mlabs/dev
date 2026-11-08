# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require "dev/environment_image"
require "dev/lifecycle/snapshot"
require "dev/project_container"

module Dev
  # Runs the project's dependency install inside its build container:
  # `dev deps install`, as the container's own dev, in the container's
  # workspace at a snapshot of the checkout (ProjectContainer, dev#421).
  # The container is a build host with its own data root (ADR-0008), so
  # this is the install of the whole linux lock — toolchain, gh trees,
  # gems — into the container's volumes, and the lisps it writes land in
  # the workspace the container's commands run from. The image's run_env
  # and the host's gh token ride in as every command's do: the private
  # releases the container fetches for itself need the auth the host
  # already holds.
  class ContainerDepsInstaller
    extend T::Sig

    # The in-container install exited nonzero.
    class InstallFailedError < StandardError
      extend T::Sig

      # @param container [String] the container name
      sig { params(container: String).void }
      def initialize(container:)
        super("dev: dev deps install failed inside #{container}")
      end
    end

    # The words the container's dev runs.
    INSTALL = T.let(%w[dev deps install].freeze, T::Array[String])

    # @param containers [ProjectContainer] the way into the project's containers
    sig { params(containers: ProjectContainer).void }
    def initialize(containers:)
      @containers = containers
    end

    # Install the project's dependencies in +container+.
    #
    # @param container [String] the running container's name
    # @param image [EnvironmentImage] the container's image, whose `run_env` the install carries
    # @param snapshot [Lifecycle::Snapshot] the checkout the install reads, pushed
    # @return [void]
    # @raise [InstallFailedError] when the install exits nonzero
    sig { params(container: String, image: EnvironmentImage, snapshot: Lifecycle::Snapshot).void }
    def install!(container, image:, snapshot:)
      status = @containers.exec_in(container, image:, argv: INSTALL, snapshot:)
      raise InstallFailedError.new(container:) unless status.zero?
    end
  end
end

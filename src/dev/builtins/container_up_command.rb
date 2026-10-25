# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/builtins/container_command"
require "dev/builtins/service_up"
require "dev/container_deps_installer"
require "dev/container_dev_provisioner"
require "dev/container_user_aligner"
require "dev/credentials"
require "dev/engine_provisioner"
require "dev/host_rule"
require "dev/project_images"

module Dev
  module Builtins
    # `dev container up` — everything a containerized command needs before it
    # runs, done ahead of time: the engine up and sized from this repo's
    # hint, once; then, image by image (ProjectImages#all, dev#307), the
    # image resolved (local → registry → build) and, when the image
    # persists its container, the service container created or restarted
    # warm, its dev converged to the host's, and its side of the dependency
    # install run. `dev up` composes this after the host-side dependency
    # install; a CI job runs it alone to publish the images
    # (`DEV_PUBLISH_IMAGE=1`).
    #
    # The build containers are this project's service dependency (an
    # environment service: commands execute in them), so this is the
    # ServiceUp port `dev up` composes; `call` is the CLI adapter over it.
    #
    # The host rule, asked of each image (HostRule; ADR-0007 as amended by
    # dev#308): a container is needed exactly when this host was not
    # provisioned from the image. A host that was — its marker is the
    # lock's pin — installs everything itself and runs that image's
    # commands directly, so there is nothing to bring up for it: no image,
    # no container (and no engine, when every image is skipped). A host
    # whose marker names the image under another digest has drifted: it is
    # brought up like any other host and told so, and dev never converges
    # its OS toward the lock. The one exception to "nothing to bring up" is
    # the publisher designation (DEV_PUBLISH_IMAGE=1): a native host still
    # resolves the image so the registry has it for the hosts that do need
    # it, and still starts no container.
    class ContainerUpCommand < ContainerCommand
      extend T::Sig
      include ServiceUp

      # What to report for each alignment outcome that changed something;
      # an already-aligned user (the steady state) says nothing.
      USER_ALIGNMENT = T.let(
        {
          realigned: "dev: container user took the data root owner's uid and gid",
          adopted: "dev: container user took over the root-owned data root",
        }.freeze,
        T::Hash[Symbol, String],
      )

      # @param container_client [Dev::BuildContainer, nil]
      # @param engine_provisioner [Dev::EngineProvisioner] the sizing step
      # @param user_aligner [Dev::ContainerUserAligner, nil] makes the
      #   container's user the mounted data root's owner; resolved lazily
      #   over the client's engine when not injected, like the client
      # @param dev_provisioner [Dev::ContainerDevProvisioner, nil] converges
      #   the persistent container's dev to this host's version; resolved
      #   lazily the same way
      # @param deps_installer [Dev::ContainerDepsInstaller, nil] runs the
      #   container-side dependency install; resolved lazily the same way
      # @param out [IO, StringIO]
      # @param host_rule [Dev::HostRule] whether an image's work runs here
      sig do
        params(
          container_client: T.nilable(Dev::BuildContainer),
          engine_provisioner: Dev::EngineProvisioner,
          user_aligner: T.nilable(Dev::ContainerUserAligner),
          dev_provisioner: T.nilable(Dev::ContainerDevProvisioner),
          deps_installer: T.nilable(Dev::ContainerDepsInstaller),
          out: T.any(IO, StringIO),
          host_rule: Dev::HostRule,
        ).void
      end
      def initialize(container_client: nil, engine_provisioner: Dev::EngineProvisioner.new,
                     user_aligner: nil, dev_provisioner: nil, deps_installer: nil, out: $stdout,
                     host_rule: Dev::HostRule.new)
        super(container_client:, out:)
        @engine_provisioner = engine_provisioner
        @user_aligner = user_aligner
        @dev_provisioner = dev_provisioner
        @deps_installer = deps_installer
        @host_rule = host_rule
      end

      sig { override.returns(String) }
      def desc = "Bring the engine up, resolve the build image, start the persistent container"

      # The CLI verb: an adapter over the ServiceUp port.
      #
      # @param args [Array<String>] unused
      # @param context [ExecutionContext] the project (the group is gated on build.container)
      # @return [void]
      sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).void }
      def call(args:, context:)
        up(project: context.project!)
      end

      # @param project [ProjectContext] the checkout (its images are the service's)
      # @return [void]
      sig { override.params(project: ProjectContext).void }
      def up(project:)
        images = project.project_images
        provision_engine!(project, images.all.reject { |image| host_is?(image) && !publish_image? })
        images.all.each do |image|
          if host_is?(image)
            ensure_image!(image, images) if publish_image?
            report_native(image)
            next
          end

          report_drift(image)
          image_tag = ensure_image!(image, images)
          next unless image.persist

          name = client.ensure_service!(image_tag, project_root: project.root, volumes: image.volumes)
          @out.puts "dev: build container up: #{name}"
          provision_inside!(name, image)
        end
      end

      # The cold topology: the same images, a one-shot container of each
      # over the throwaway data root the caller made current (ColdRoot), the
      # same in-container provisioning — then the container is gone. The
      # persistent containers, warm root mounted at their creation, are
      # never touched. Persisted or not, the shape is the same: a cold run
      # proves the project provisions from nothing.
      #
      # @param project [ProjectContext]
      # @return [void]
      sig { override.params(project: ProjectContext).void }
      def cold_up(project:)
        images = project.project_images
        provision_engine!(project, images.all.reject { |image| host_is?(image) })
        images.all.each do |image|
          if host_is?(image)
            report_native(image)
            next
          end

          report_drift(image)
          image_tag = ensure_image!(image, images)
          client.with_one_shot_container(image_tag, project_root: project.root, volumes: image.volumes) do |name|
            @out.puts "dev: cold container up: #{name}"
            provision_inside!(name, image)
          end
        end
      end

      private

      # Whether the image's work runs on this host (the host rule, asked
      # per image).
      #
      # @param image [ProjectImages::Image]
      # @return [Boolean]
      sig { params(image: ProjectImages::Image).returns(T::Boolean) }
      def host_is?(image)
        @host_rule.native?(image)
      end

      # Engine up and sized from the project's hint, once — and not at all
      # when no image needs it.
      #
      # @param project [ProjectContext]
      # @param needing [Array<ProjectImages::Image>] the images about to be resolved
      # @return [void]
      sig { params(project: ProjectContext, needing: T::Array[ProjectImages::Image]).void }
      def provision_engine!(project, needing)
        @engine_provisioner.provision!(resources: project.engine) if needing.any?
      end

      # The publisher designation: the provisioning step that volunteers to
      # make sure the registry has the content-addressed image (see
      # CommandRunner#publish_image? for why an env var, not a command name).
      #
      # @return [Boolean]
      sig { returns(T::Boolean) }
      def publish_image?
        ENV["DEV_PUBLISH_IMAGE"] == "1"
      end

      # @param image [ProjectImages::Image] an image whose work runs here
      # @return [void]
      sig { params(image: ProjectImages::Image).void }
      def report_native(image)
        @out.puts "dev: #{@host_rule.why_native(image)} — #{image.name}'s commands run here, no container"
      end

      # Name both digests when this host was provisioned from the image
      # under another recipe: the container is the fallback until whoever
      # owns the host re-images it.
      #
      # @param image [ProjectImages::Image] an image whose work runs in a container
      # @return [void]
      sig { params(image: ProjectImages::Image).void }
      def report_drift(image)
        return unless @host_rule.drifted?(image)

        pinned = T.cast(image, EnvironmentImage)
        @out.puts "dev: this host was provisioned from #{@host_rule.host} but the lock's #{image.name} is " \
                  "#{image.name}@#{pinned.short_digest} — its commands run inside until this host is re-imaged"
      end

      # The image resolved (local → registry → build) — the lock's pin or
      # the deprecated Dockerfile, ProjectImages' call.
      #
      # @param image [ProjectImages::Image]
      # @param images [ProjectImages]
      # @return [String] the image reference
      sig { params(image: ProjectImages::Image, images: ProjectImages).returns(String) }
      def ensure_image!(image, images)
        image_tag = images.ensure!(image, client:, publish: publish_image?)
        @out.puts "dev: image ready: #{image_tag}"
        image_tag
      end

      # What a running container needs before a command runs in it: a user
      # that can write its data root, the host's dev, then its own install
      # of the lock (the container is a build host, ADR-0008).
      #
      # @param name [String] the running container
      # @param image [ProjectImages::Image] whose `run_env` the install carries
      # @return [void]
      sig { params(name: String, image: ProjectImages::Image).void }
      def provision_inside!(name, image)
        # Everything below writes the mounted data root as the container's
        # user, so that user becomes the mount's owner first — a no-op where
        # the ids already agree, reported only when it did something.
        aligned = user_aligner.align!(name)
        @out.puts USER_ALIGNMENT.fetch(aligned) if USER_ALIGNMENT.key?(aligned)
        # The container follows the host: its dev is converged to this exact
        # version here, on every up, so a host upgrade re-syncs it with no
        # manual step and the steady state is one probe.
        result = dev_provisioner.provision!(name)
        @out.puts "dev: container dev #{result} at #{dev_provisioner.host_version}"
        # Dependencies install where they are consumed: with the container's
        # dev current, its side of the install runs there (gems against the
        # store Ruby, container-scoped brew deps), carrying the run_env the
        # install-time integrations may need.
        deps_installer.install!(name, env: Dev::Credentials.resolve_run_env(image.run_env))
        @out.puts "dev: container deps installed"
      end

      # @return [Dev::ContainerUserAligner]
      sig { returns(Dev::ContainerUserAligner) }
      def user_aligner
        @user_aligner ||= Dev::ContainerUserAligner.new(engine: client.engine)
      end

      # @return [Dev::ContainerDevProvisioner]
      sig { returns(Dev::ContainerDevProvisioner) }
      def dev_provisioner
        @dev_provisioner ||= Dev::ContainerDevProvisioner.new(engine: client.engine)
      end

      # @return [Dev::ContainerDepsInstaller]
      sig { returns(Dev::ContainerDepsInstaller) }
      def deps_installer
        @deps_installer ||= Dev::ContainerDepsInstaller.new(engine: client.engine)
      end
    end
  end
end

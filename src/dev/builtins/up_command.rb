# typed: strict
# frozen_string_literal: true

require "dev/command"
require "dev/credentials"
require "dev/builtins/container_up_command"
require "dev/host_service"

module Dev
  module Builtins
    # `dev up` is a virtual slot: this builtin installs locked deps, and a
    # project `up:` command in dev.yml overrides it into an OverriddenCommand
    # — the builtin install runs first (super()), then the project's
    # provisioning. Projects with only a dependencies.rb get `dev up` for
    # free. `up` also ensures the `dev cd` shell hook (idempotent) —
    # provisioning is where dev's RC hooks land, next to the shadowenv one.
    #
    # `up` is a hybrid command: its host half (converge + RC hook) always
    # runs, and its project half requires the project context. Outside any
    # project the host half IS the fresh-box bootstrap — install dev,
    # `dev up`, ready — so a nil project is a supported state, not an error.
    class UpCommand < BuiltinCommand
      extend T::Sig

      # @param install_deps_command [InstallDepsCommand] the `dev deps install` body
      # @param host_service [Dev::HostService] the host layer
      # @param container_up_command [ContainerUpCommand] the `dev container up`
      #   body, run only when the project declares a build container
      sig do
        params(
          install_deps_command: InstallDepsCommand,
          host_service: Dev::HostService,
          container_up_command: ContainerUpCommand,
        ).void
      end
      def initialize(install_deps_command:, host_service: Dev::HostService.new,
        container_up_command: ContainerUpCommand.new)
        super()
        @install_deps_command = install_deps_command
        @host_service = host_service
        @container_up_command = container_up_command
      end

      sig { override.returns(String) }
      def desc = "Install locked deps and bring the build container up, then run the project's up command (if defined)"

      sig { override.returns(Command::Category) }
      def category = Command::Category::Lifecycle

      # up IS the staleness remediation — never nag before it.
      sig { override.returns(T::Boolean) }
      def staleness_exempt? = true

      # `dev up` treats a stale stamp as its expected precondition and
      # rewrites it after a fully-successful run.
      sig { override.returns(T::Boolean) }
      def stamps? = true

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        # The host layer converges before project provisioning (self-update
        # + org Brewfile): project installs may lean on host tools (gh,
        # rbenv). Warn-only — never blocks the project. Shipped skills link
        # here too: `up` is the fresh-box bootstrap, so the machine's skill
        # links must exist after it, not after the first `dev plan`.
        @host_service.converge_tooling
        @host_service.install_rc_hook
        @host_service.install_skills
        project = context.project
        if project.nil?
          # In-project runs sync learnings via the composed dev deps install
          # (project-linked); the projectless bootstrap syncs the machine
          # artifacts here or a fresh box would have none.
          @host_service.sync_learnings(project_root: nil)
          puts "dev: host layer converged."
          puts "dev: no dev.yml here — run dev up inside a project to provision it too."
          return
        end

        provision_build_credentials(project)
        @install_deps_command.call(args:, context:)
        # After the install: the image build may mount locked build deps
        # (version-resolved volumes), so they must be on disk first. After
        # `dev up` the first containerized command finds engine, image and
        # container ready instead of paying for them lazily.
        @container_up_command.call(args: [], context:) if project.build_container
      end

      private

      # `dev up` is the provisioning command: after it succeeds, every other
      # command should work unattended. Resolving docker build args here
      # (prompting and storing credentials on first run) keeps the lazily
      # triggered image build in containerized commands non-interactive.
      sig { params(project: ProjectContext).void }
      def provision_build_credentials(project)
        config = project.build_container
        return if config.nil? || config.build_args.empty?

        Dev::Credentials.resolve_build_args(config.build_args)
      end
    end
  end
end

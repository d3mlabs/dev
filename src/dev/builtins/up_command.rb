# typed: strict
# frozen_string_literal: true

require "dev/command"
require "dev/credentials"
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

      sig do
        params(
          install_deps_command: InstallDepsCommand,
          host_service: Dev::HostService,
        ).void
      end
      def initialize(install_deps_command:, host_service: Dev::HostService.new)
        super()
        @install_deps_command = T.let(install_deps_command, InstallDepsCommand)
        @host_service = T.let(host_service, Dev::HostService)
      end

      sig { override.returns(String) }
      def desc = "Install locked dependencies, then run the project's up command (if defined)"

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
        # rbenv). Warn-only — never blocks the project.
        @host_service.converge_tooling
        @host_service.install_rc_hook
        project = context.project
        if project.nil?
          puts "dev: host layer converged."
          puts "dev: no dev.yml here — run dev up inside a project to provision it too."
          return
        end

        provision_build_credentials(project)
        @install_deps_command.call(args:, context:)
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

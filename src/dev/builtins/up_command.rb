# typed: strict
# frozen_string_literal: true

require "dev/cd"
require "dev/command"
require "dev/credentials"

module Dev
  module Builtins
    # `dev up` is a virtual slot: this builtin installs locked deps, and a
    # project `up:` command in dev.yml overrides it into an OverriddenCommand
    # — the builtin install runs first (super()), then the project's
    # provisioning. Projects with only a dependencies.rb get `dev up` for
    # free. `up` also ensures the `dev cd` shell hook (idempotent) —
    # provisioning is where dev's RC hooks land, next to the shadowenv one.
    class UpCommand < BuiltinCommand
      extend T::Sig

      sig do
        params(
          install_deps_command: InstallDepsCommand,
          hook_installer: Dev::Cd::HookInstaller,
        ).void
      end
      def initialize(install_deps_command:, hook_installer: Dev::Cd::HookInstaller.new)
        super()
        @install_deps_command = install_deps_command
        @hook_installer = hook_installer
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
        provision_build_credentials(context)
        @hook_installer.ensure_installed
        @install_deps_command.call(args:, context:)
      end

      private

      # `dev up` is the provisioning command: after it succeeds, every other
      # command should work unattended. Resolving docker build args here
      # (prompting and storing credentials on first run) keeps the lazily
      # triggered image build in containerized commands non-interactive.
      sig { params(context: ExecutionContext).void }
      def provision_build_credentials(context)
        config = context.build_container
        return if config.nil? || config.build_args.empty?

        Dev::Credentials.resolve_build_args(config.build_args)
      end
    end
  end
end

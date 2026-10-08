# typed: strict
# frozen_string_literal: true

require "dev/command"
require "dev/credentials"
require "dev/builtins/service_up"
require "dev/cold_root"
require "dev/container_context"
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
    #
    # `dev up --no-cache` is the project half as a cold run: a throwaway
    # data root, a one-shot container, nothing reused and nothing kept.
    class UpCommand < BuiltinCommand
      extend T::Sig

      # `dev up --no-cache`: the cold run topology (see call_cold).
      NO_CACHE_FLAG = "--no-cache"

      # @param install_deps_command [InstallDepsCommand] the `dev deps install`
      #   body — a CLI intent `dev up` extends, so it receives the user's args
      # @param host_service [Dev::HostService] the host layer
      # @param service_dependencies [Array<ServiceUp>] the services this
      #   project depends on — things that must be *running* for it to build
      #   and run — through the one port `dev up` needs from each: bring-up,
      #   given the project. They are operations, not CLI intents: `dev up`
      #   orchestrates them and never hands them the user's args (contrast
      #   install_deps_command). Composed in bring-up order at the root from
      #   dev.yml: the build container (an environment service,
      #   `build.container`) today; application services later. What this
      #   project provides to others is never in this list.
      # @param inside_container [Boolean] whether this dev runs inside a
      #   dev-managed container (ContainerContext). Inside, `up` is the deps
      #   install alone: the host layer, credentials and service bring-up
      #   belong to the host dev that started the container.
      sig do
        params(
          install_deps_command: InstallDepsCommand,
          host_service: Dev::HostService,
          service_dependencies: T::Array[ServiceUp],
          inside_container: T::Boolean,
        ).void
      end
      def initialize(install_deps_command:, host_service: Dev::HostService.new, service_dependencies: [],
                     inside_container: Dev::ContainerContext.inside?)
        super()
        @install_deps_command = install_deps_command
        @host_service = host_service
        @service_dependencies = service_dependencies
        @inside_container = inside_container
      end

      sig { override.returns(String) }
      def desc = "Install locked deps and bring the build container up, then run the project's up command (if defined); --no-cache does it from nothing"

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
        no_cache = args.include?(NO_CACHE_FLAG)
        args -= [NO_CACHE_FLAG]
        return call_inside(args:, context:, no_cache:) if @inside_container
        return call_cold(args:, context:) if no_cache

        # The host layer converges before project provisioning (self-update
        # + org Brewfile): project installs may lean on host tools (gh,
        # rbenv). Warn-only — never blocks the project. Shipped skills link
        # here too: `up` is the fresh-box bootstrap, so the machine's skill
        # links must exist after it, not after the first `dev plan`.
        @host_service.converge_tooling
        @host_service.install_rc_hook
        @host_service.sync_skills(project_root: nil)
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
        # After the install: a service's bring-up may need locked deps on
        # disk (the build container's image build mounts version-resolved
        # volumes). After `dev up` the first command that needs a service
        # finds it running instead of paying for it lazily.
        @service_dependencies.each { |service| service.up(project:) }
      end

      private

      # The cold shape of `up` (`--no-cache`): the project half alone, run
      # from nothing — a throwaway data root stands in for the warm one for
      # the duration (ColdRoot), the install lands there, and each service
      # does its cold bring-up (a one-shot container for the build
      # container) over it. The warm store and the persistent container are
      # not touched; the host layer is not converged — a cold run proves the
      # project provisions, and `dev up` is what converges the host.
      #
      # @param args [Array<String>] the user's args, less the flag
      # @param context [ExecutionContext]
      # @return [void]
      sig { params(args: T::Array[String], context: ExecutionContext).void }
      def call_cold(args:, context:)
        project = context.project
        if project.nil?
          puts "dev: dev up --no-cache needs a project — it provisions one from nothing."
          return
        end

        provision_build_credentials(project)
        Dev::ColdRoot.with do |root|
          puts "dev: cold run — data root #{root} (removed afterwards)"
          @install_deps_command.call(args:, context:)
          @service_dependencies.each { |service| service.cold_up(project:) }
        end
      end

      # The inside shape of `up`: the deps install and nothing else. There is
      # no host layer to converge (the container's dev is provisioned by the
      # host's and cannot self-update), no credentials to prompt for (the host
      # resolves and injects them), and no service to bring up (we are in it).
      #
      # @param args [Array<String>] the user's args, handed to the install body
      # @param context [ExecutionContext]
      # @param no_cache [Boolean] whether `--no-cache` was asked for — a
      #   host-side topology (throwaway root, one-shot container) that has no
      #   meaning here; reported, then the plain install runs
      # @return [void]
      sig { params(args: T::Array[String], context: ExecutionContext, no_cache: T::Boolean).void }
      def call_inside(args:, context:, no_cache:)
        if context.project.nil?
          puts "dev: inside a container with no dev.yml — nothing to provision."
          return
        end

        puts "dev: #{NO_CACHE_FLAG} runs from the host (a throwaway data root and a one-shot container) — ignored inside." if no_cache
        @install_deps_command.call(args:, context:)
      end

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

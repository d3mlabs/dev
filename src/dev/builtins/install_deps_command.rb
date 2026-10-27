# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/command"
require "dev/container_context"
require "dev/deps"
require "dev/deps/local_store"
require "dev/deps/integration"
require "dev/deps/lockfile"
require "dev/deps/registry"
require "dev/host_service"
require "dev/shadowenv_trust"

module Dev
  module Builtins
    # `dev deps install [--group <g>]... [--except <g>]... [--integration <i>]... [--pinned-taps]`:
    # install what the lockfile pins for this machine, optionally narrowed to
    # dependency groups and integrations — shared with the `up` builtin,
    # which composes this command. Every build host runs the same install
    # against its own data root (ADR-0008), the project's interpreters
    # included: the locked Ruby and Python are brew pins that install and
    # activate in brew's batch ahead of bundler and pip, on a workstation and
    # inside the build container alike (dev#269). The only inside/outside
    # difference is that the host-side hygiene hooks (skill links, learnings)
    # stay off inside.
    # `--group build --integration brew` narrows an install to the toolchain
    # the lock pins; `--pinned-taps` is the reproducible mode: brew installs
    # from taps checked out at the commits the lock names instead of from
    # brew's moving API (BrewIntegration).
    class InstallDepsCommand < BuiltinCommand
      extend T::Sig

      # The repeatable narrowing flags (`--group build --group=test`).
      GROUP_FLAG = "--group"
      EXCEPT_FLAG = "--except"
      INTEGRATION_FLAG = "--integration"
      PINNED_TAPS_FLAG = "--pinned-taps"

      # Builds the Installer for a lockfile + integrations pair;
      # injected so tests can substitute a fake without touching the host.
      InstallerFactory = T.type_alias do
        T.proc.params(
          lockfile: Dev::Deps::Lockfile,
          integrations: T::Hash[Symbol, Dev::Deps::Integration],
        ).returns(Dev::Deps::Installer)
      end

      # @param shadowenv_trust [Dev::ShadowenvTrust] trusts the project's
      #   shadowenv for the running user before the integrations spawn under it
      # @param inside_container [Boolean] whether this dev runs inside a
      #   dev-managed container (ContainerContext): the host-side hygiene
      #   hooks stay off there
      sig do
        params(
          installer_factory: InstallerFactory,
          host_service: Dev::HostService,
          shadowenv_trust: Dev::ShadowenvTrust,
          inside_container: T::Boolean,
        ).void
      end
      def initialize(
        installer_factory: ->(lockfile, integrations) {
          Dev::Deps::Installer.new(lockfile:, integrations:)
        },
        host_service: Dev::HostService.new,
        shadowenv_trust: Dev::ShadowenvTrust.new,
        inside_container: Dev::ContainerContext.inside?
      )
        super()
        @installer_factory = installer_factory
        @host_service = host_service
        @shadowenv_trust = shadowenv_trust
        @inside_container = inside_container
      end

      sig { override.returns(String) }
      def desc = "Install locked dependencies on this machine (--group/--except/--integration narrow; --pinned-taps pins brew's taps)"

      sig { override.returns(Command::Category) }
      def category = Command::Category::Lifecycle

      sig { override.returns(T::Array[Cli::Flag]) }
      def flags
        [
          Cli::Flag.new(GROUP_FLAG, takes_value: true),
          Cli::Flag.new(EXCEPT_FLAG, takes_value: true),
          Cli::Flag.new(INTEGRATION_FLAG, takes_value: true),
          Cli::Flag.new(PINNED_TAPS_FLAG),
        ]
      end

      # dev deps install IS the remediation for a stale install — never nag
      # before it.
      sig { override.returns(T::Boolean) }
      def staleness_exempt? = true

      # A fully-successful install records the installed stamp (the CI-side
      # install path of the staleness check).
      sig { override.returns(T::Boolean) }
      def stamps? = true

      # Install-time has no loaded dependencies.rb, so config-level inputs
      # default: install everything the lockfiles pin, filtered to the
      # detected env and host OS so e.g. a Mac never downloads the Linux
      # engine, then to the groups and integrations named on the command line.
      sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).void }
      def call(args:, context:)
        project = context.project!
        env = Dev::Deps.detect_env
        host = Dev::Deps.detect_host
        pin_taps = args.flag?(PINNED_TAPS_FLAG)
        groups = symbol_flags(args, GROUP_FLAG)
        except = symbol_flags(args, EXCEPT_FLAG) || []
        integration_types = symbol_flags(args, INTEGRATION_FLAG)
        lockfile = Dev::Deps::Lockfile.new(dir: project.root)

        # The integrations spawn under the project's shadowenv (bundler, pip
        # — ShadowenvExec), which refuses a directory this user has not
        # trusted. Trust is the user's, not the files': a fresh container's
        # builder over an already-written .shadowenv.d has none, and the
        # writers only trust after a write (Dev::ShadowenvTrust).
        @shadowenv_trust.ensure!(project_root: project.root)
        installer = @installer_factory.call(lockfile, integrations(project, pin_taps:))
        installer.install(env:, host:, groups:, except:, integration_types:)
        return if @inside_container

        # Installing a dependency includes its shipped skills: finish by
        # materializing the skill channels (the locked gem set's land
        # project-scoped), and refresh the machine's org learnings artifacts
        # (both hooks are best-effort and never raise).
        # This is hygiene, not a bootstrap contract: workflows that must start
        # on fresh invariants (e.g. ai-flow's runner) run an explicit blocking
        # `dev learnings sync` step instead of relying on this side effect.
        # Host-side only: the links land in the mounted project tree and must
        # name the host's gem paths, and the learnings are the host's.
        @host_service.sync_skills(project_root: project.root)
        @host_service.sync_learnings(project_root: project.root)
      end

      private

      # The integrations that install on this build host — the same set on a
      # workstation, a box and inside a build container, each against its own
      # data root (ADR-0008).
      #
      # @param project [ProjectContext]
      # @param pin_taps [Boolean] brew installs from taps pinned at the lock's commits
      # @return [Hash{Symbol => Dev::Deps::Integration}]
      sig { params(project: ProjectContext, pin_taps: T::Boolean).returns(T::Hash[Symbol, Dev::Deps::Integration]) }
      def integrations(project, pin_taps:)
        Dev::Deps::Registry.host_integrations(project_root: project.root, store: Dev::Deps::LocalStore.new, pin_taps:)
      end

      # The symbols named by a repeatable flag, or nil when the flag never
      # appears (nil is the Installer's "no narrowing on this axis").
      #
      # @param args [Array<String>] the command's argv
      # @param flag [String] GROUP_FLAG, EXCEPT_FLAG or INTEGRATION_FLAG
      # @return [Array<Symbol>, nil]
      sig { params(args: Cli::ParsedArgs, flag: String).returns(T.nilable(T::Array[Symbol])) }
      def symbol_flags(args, flag)
        names = args.values(flag)
        return nil if names.empty?

        names.map(&:to_sym)
      end
    end
  end
end

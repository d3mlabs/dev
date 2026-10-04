# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/cli/flag_parser"
require "dev/command"
require "dev/deps"
require "dev/deps/cache"
require "dev/deps/gem_skill_linker"
require "dev/deps/integration"
require "dev/deps/lockfile"
require "dev/deps/registry"
require "dev/host_service"
require "dev/shadowenv_ruby"

module Dev
  module Builtins
    # `dev deps install [--group <g>]... [--except <g>]... [--integration <i>]...`:
    # install what the lockfiles pin for this machine, optionally narrowed to
    # dependency groups and integrations — shared with the `up` builtin,
    # which composes this command. Host integrations install on the host
    # (not the build container) so their artifacts can be volume-mounted in.
    # `--group build --integration brew` is how a container image bootstrap
    # installs its toolchain from the lock (bin/docker-install-build-deps.sh)
    # without pulling the host-installed artifacts the same group pins.
    class InstallDepsCommand < BuiltinCommand
      extend T::Sig

      # Builds the Installer for a lockfile + integrations pair;
      # injected so tests can substitute a fake without touching the host.
      InstallerFactory = T.type_alias do
        T.proc.params(
          lockfile: Dev::Deps::Lockfile,
          integrations: T::Hash[Symbol, Dev::Deps::Integration],
        ).returns(Dev::Deps::Installer)
      end

      # Builds the project-scoped gem skill linker (the project root is a
      # per-call value, so the collaborator arrives as a factory).
      GemSkillLinkerFactory = T.type_alias do
        T.proc.params(project_root: Pathname).returns(Dev::Deps::GemSkillLinker)
      end

      sig do
        params(
          installer_factory: InstallerFactory,
          gem_skill_linker_factory: GemSkillLinkerFactory,
          host_service: Dev::HostService,
          flag_parser: Cli::FlagParser,
        ).void
      end
      def initialize(
        installer_factory: ->(lockfile, integrations) {
          Dev::Deps::Installer.new(lockfile:, integrations:)
        },
        gem_skill_linker_factory: ->(project_root) { Dev::Deps::GemSkillLinker.new(project_root:) },
        host_service: Dev::HostService.new,
        flag_parser: Cli::FlagParser.new
      )
        super()
        @installer_factory = installer_factory
        @gem_skill_linker_factory = gem_skill_linker_factory
        @host_service = host_service
        @flag_parser = flag_parser
      end

      sig { override.returns(String) }
      def desc = "Install locked dependencies on this machine (--group/--except/--integration narrow the set)"

      sig { override.returns(Command::Category) }
      def category = Command::Category::Lifecycle

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
      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        project = context.project!
        env = Dev::Deps.detect_env
        host = Dev::Deps.detect_host
        groups = symbol_flags(args, "--group")
        except = symbol_flags(args, "--except") || []
        integration_types = symbol_flags(args, "--integration")
        lockfile = Dev::Deps::Lockfile.new(dir: project.root)

        # Headless boxes (CI, runner services) reach dev deps install before any
        # dev.yml command has run CommandRunner's provisioning, so the builtin
        # must provision the pinned Ruby itself — bundler installs against it.
        # converge!, not ensure!: a converge verb re-checks the installed
        # ruby's health behind a current lisp (#204). A selection that locks no
        # gems (e.g. --group build in an image bootstrap) needs no project Ruby.
        selection = Dev::Deps::Installer.select(lockfile.read, env:, host:, groups:, except:, integration_types:)
        if selection.any? { |dep| dep.integration == :bundler }
          ShadowenvRuby.converge!(ruby_version: project.ruby_version, project_root: project.root)
        end

        installer = @installer_factory.call(
          lockfile,
          Dev::Deps::Registry.host_integrations(
            project_root: project.root,
            cache: Dev::Deps::Cache.new,
            python_version: project.python_version,
          ),
        )
        installer.install(env:, host:, groups:, except:, integration_types:)
        # Installing a dependency includes its shipped skills: finish by linking
        # the locked gem set's skills project-scoped, and refresh the machine's
        # org learnings artifacts (both hooks are best-effort and never raise).
        # This is hygiene, not a bootstrap contract: workflows that must start
        # on fresh invariants (e.g. ai-flow's runner) run an explicit blocking
        # `dev learnings sync` step instead of relying on this side effect.
        @gem_skill_linker_factory.call(project.root).link_all
        @host_service.sync_learnings(project_root: project.root)
      end

      private

      # The symbols named by a repeatable flag, or nil when the flag never
      # appears (nil is the Installer's "no narrowing on this axis").
      #
      # @param args [Array<String>] the command's argv
      # @param flag [String] "--group", "--except" or "--integration"
      # @return [Array<Symbol>, nil]
      sig { params(args: T::Array[String], flag: String).returns(T.nilable(T::Array[Symbol])) }
      def symbol_flags(args, flag)
        names = @flag_parser.values(args, flag)
        return nil if names.empty?

        names.map(&:to_sym)
      end
    end
  end
end

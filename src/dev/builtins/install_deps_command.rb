# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/cli/flag_parser"
require "dev/command"
require "dev/container_context"
require "dev/container_ruby"
require "dev/deps"
require "dev/deps/local_store"
require "dev/deps/gem_skill_linker"
require "dev/deps/integration"
require "dev/deps/lockfile"
require "dev/deps/registry"
require "dev/host_service"
require "dev/shadowenv_ruby"

module Dev
  module Builtins
    # `dev deps install [--group <g>]... [--except <g>]... [--integration <i>]... [--pinned-taps]`:
    # install what the lockfiles pin for this machine, optionally narrowed to
    # dependency groups and integrations — shared with the `up` builtin,
    # which composes this command. Dependencies install where they are
    # consumed: on the host the host-scoped integrations run against the
    # host Ruby; inside the build container the container-scoped ones run
    # against the store Ruby (Registry's scope axis says which is which, and
    # a BOTH type like bundler installs separately on each side). The two
    # sides share the artifact store through the data-root mount, so a file
    # artifact fetched on the host is already there inside.
    # `--group build --integration brew` is how a container image bootstrap
    # installs its toolchain from the lock (bin/docker-install-build-deps.sh)
    # without pulling the host-installed artifacts the same group pins; inside
    # the resulting container the install defaults to `--except build` for the
    # same reason. `--pinned-taps` is the image build's reproducible mode:
    # brew installs from taps checked out at the commits the lock names
    # instead of from brew's moving API (BrewIntegration).
    class InstallDepsCommand < BuiltinCommand
      extend T::Sig

      PINNED_TAPS_FLAG = "--pinned-taps"

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

      # @param inside_container [Boolean] whether this dev runs inside a
      #   dev-managed container (ContainerContext). Inside, the build group is
      #   excluded by default: the image bootstrap already installed it.
      # @param container_ruby [Dev::ContainerRuby] the in-container Ruby
      #   provisioner (used only inside)
      sig do
        params(
          installer_factory: InstallerFactory,
          gem_skill_linker_factory: GemSkillLinkerFactory,
          host_service: Dev::HostService,
          flag_parser: Cli::FlagParser,
          inside_container: T::Boolean,
          container_ruby: Dev::ContainerRuby,
        ).void
      end
      def initialize(
        installer_factory: ->(lockfile, integrations) {
          Dev::Deps::Installer.new(lockfile:, integrations:)
        },
        gem_skill_linker_factory: ->(project_root) { Dev::Deps::GemSkillLinker.new(project_root:) },
        host_service: Dev::HostService.new,
        flag_parser: Cli::FlagParser.new,
        inside_container: Dev::ContainerContext.inside?,
        container_ruby: Dev::ContainerRuby.new
      )
        super()
        @installer_factory = installer_factory
        @gem_skill_linker_factory = gem_skill_linker_factory
        @host_service = host_service
        @flag_parser = flag_parser
        @inside_container = inside_container
        @container_ruby = container_ruby
      end

      sig { override.returns(String) }
      def desc = "Install locked dependencies on this machine (--group/--except/--integration narrow the set; " \
        "--pinned-taps installs brew from the lock's tap commits)"

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
        pin_taps = args.include?(PINNED_TAPS_FLAG)
        args -= [PINNED_TAPS_FLAG]
        groups = symbol_flags(args, "--group")
        except = symbol_flags(args, "--except") || default_except
        integration_types = symbol_flags(args, "--integration")
        lockfile = Dev::Deps::Lockfile.new(dir: project.root)

        # Headless boxes (CI, runner services) reach dev deps install before any
        # dev.yml command has run CommandRunner's provisioning, so the builtin
        # must provision the pinned Ruby itself — bundler installs against it.
        # converge!, not ensure!: a converge verb re-checks the installed
        # ruby's health behind a current lisp (#204). A selection that locks no
        # gems (e.g. --group build in an image bootstrap) needs no project Ruby.
        selection = Dev::Deps::Installer.select(lockfile.read, env:, host:, groups:, except:, integration_types:)
        converge_ruby!(project) if selection.any? { |dep| dep.integration == :bundler }

        installer = @installer_factory.call(lockfile, integrations(project, pin_taps:))
        installer.install(env:, host:, groups:, except:, integration_types:)
        return if @inside_container

        # Installing a dependency includes its shipped skills: finish by linking
        # the locked gem set's skills project-scoped, and refresh the machine's
        # org learnings artifacts (both hooks are best-effort and never raise).
        # This is hygiene, not a bootstrap contract: workflows that must start
        # on fresh invariants (e.g. ai-flow's runner) run an explicit blocking
        # `dev learnings sync` step instead of relying on this side effect.
        # Host-side only: the links land in the mounted project tree and must
        # name the host's gem paths, and the learnings are the host's.
        @gem_skill_linker_factory.call(project.root).link_all
        @host_service.sync_learnings(project_root: project.root)
      end

      private

      # Provision the Ruby the gems install against on this side.
      #
      # @param project [ProjectContext]
      # @return [void]
      sig { params(project: ProjectContext).void }
      def converge_ruby!(project)
        if @inside_container
          @container_ruby.converge!(ruby_version: project.ruby_version, project_root: project.root)
        else
          ShadowenvRuby.converge!(ruby_version: project.ruby_version, project_root: project.root)
        end
      end

      # The integrations that install on this side.
      #
      # @param project [ProjectContext]
      # @param pin_taps [Boolean] brew installs from taps pinned at the lock's commits
      # @return [Hash{Symbol => Dev::Deps::Integration}]
      sig { params(project: ProjectContext, pin_taps: T::Boolean).returns(T::Hash[Symbol, Dev::Deps::Integration]) }
      def integrations(project, pin_taps:)
        store = Dev::Deps::LocalStore.new
        if @inside_container
          Dev::Deps::Registry.container_integrations(
            project_root: project.root, store:, python_version: project.python_version, pin_taps:,
          )
        else
          Dev::Deps::Registry.host_integrations(
            project_root: project.root, store:, python_version: project.python_version, pin_taps:,
          )
        end
      end

      # The exclusion when no --except is given: nothing on a host; the build
      # group inside a container, where the image bootstrap (`--group build`)
      # already installed it and a second install would fight the image's
      # read-only layers. An explicit --except replaces this, never adds to it.
      #
      # @return [Array<Symbol>]
      sig { returns(T::Array[Symbol]) }
      def default_except
        @inside_container ? [:build] : []
      end

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

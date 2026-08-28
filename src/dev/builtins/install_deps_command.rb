# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/command"
require "dev/deps"
require "dev/deps/cache"
require "dev/deps/gem_skill_linker"
require "dev/deps/integration"
require "dev/deps/lockfile"
require "dev/deps/registry"
require "dev/learnings"
require "shadowenv_ruby"

module Dev
  module Builtins
    # `dev install-deps`: install everything the lockfiles pin for this
    # machine — shared with the `up` builtin, which composes this command.
    # Host integrations install on the host (not the build container) so
    # their artifacts can be volume-mounted in.
    class InstallDepsCommand < BuiltinCommand
      extend T::Sig

      # Builds the DependencyInstaller for a lockfile + integrations pair;
      # injected so tests can substitute a fake without touching the host.
      InstallerFactory = T.type_alias do
        T.proc.params(
          lockfile: Dev::Deps::Lockfile,
          integrations: T::Hash[Symbol, Dev::Deps::Integration],
        ).returns(Dev::Deps::DependencyInstaller)
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
          synchronizer: T.untyped,
        ).void
      end
      def initialize(
        installer_factory: ->(lockfile, integrations) {
          Dev::Deps::DependencyInstaller.new(lockfile:, integrations:)
        },
        gem_skill_linker_factory: ->(project_root) { Dev::Deps::GemSkillLinker.new(project_root:) },
        synchronizer: Dev::Learnings::Synchronizer.for
      )
        super()
        @installer_factory = installer_factory
        @gem_skill_linker_factory = gem_skill_linker_factory
        @synchronizer = synchronizer
      end

      sig { override.returns(String) }
      def desc = "Install locked dependencies handled on the host (e.g. gh releases)"

      sig { override.returns(Command::Category) }
      def category = Command::Category::Lifecycle

      # install-deps IS the remediation for a stale install — never nag
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
      # engine.
      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        # Headless boxes (CI, runner services) reach install-deps before any
        # dev.yml command has run CommandRunner's provisioning, so the builtin
        # must provision the pinned Ruby itself — bundler installs against it.
        ShadowenvRuby.ensure!(ruby_version: context.ruby_version, project_root: context.project_root)

        lockfile = Dev::Deps::Lockfile.new(dir: context.project_root)
        installer = @installer_factory.call(
          lockfile,
          Dev::Deps::Registry.host_integrations(
            project_root: context.project_root,
            cache: Dev::Deps::Cache.new,
            python_version: context.python_version,
          ),
        )
        installer.install(env: Dev::Deps.detect_env, host: Dev::Deps.detect_host)
        # Installing a dependency includes its shipped skills: finish by linking
        # the locked gem set's skills project-scoped, and refresh the machine's
        # org learnings artifacts (both hooks are best-effort and never raise).
        # This is hygiene, not a bootstrap contract: workflows that must start
        # on fresh invariants (e.g. ai-flow's runner) run an explicit blocking
        # `dev learnings sync` step instead of relying on this side effect.
        @gem_skill_linker_factory.call(context.project_root).link_all
        @synchronizer.sync(project_root: context.project_root)
      end
    end
  end
end

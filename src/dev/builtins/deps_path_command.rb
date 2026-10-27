# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/command"
require "dev/deps/accessor"
require "dev/deps/local_store"
require "dev/deps/lockfile"

module Dev
  module Builtins
    # `dev deps path <integration> …`: print a locked artifact's absolute
    # path, read from the lockfile + artifact store (e.g. `dev deps path
    # ficsit <mod> <platform>`). A leaf of the `deps` group.
    class DepsPathCommand < BuiltinCommand
      extend T::Sig

      # Builds the accessor over a project's lockfile (the project root is a
      # per-call value, so the collaborator arrives as a factory).
      AccessorFactory = T.type_alias do
        T.proc.params(project_root: Pathname).returns(Dev::Deps::Accessor)
      end

      sig { params(accessor_factory: AccessorFactory).void }
      def initialize(
        accessor_factory: ->(project_root) {
          Dev::Deps::Accessor.new(
            lockfile: Dev::Deps::Lockfile.new(dir: project_root),
            store: Dev::Deps::LocalStore.new,
          )
        }
      )
        super()
        @accessor_factory = accessor_factory
      end

      sig { override.returns(String) }
      def desc = "Print a locked artifact's path (path ficsit <mod> <platform> | path xcode | path gh <name> | path wwise <name>)"

      sig { override.returns(Command::Category) }
      def category = Command::Category::Lifecycle

      # A lockfile query, not a dependency consumer: it reads where the
      # locked artifact lives and nothing else. The install stamp is
      # per-checkout, so a fresh checkout over an already-populated store
      # (an agent's persistent workspace, a second worktree) is "never
      # installed" while every artifact is present — and in CI the guard
      # would refuse the lookup with a provisioning nag instead of answering.
      # Scripts call this path from hooks that must not flap on stamp state;
      # a genuinely missing artifact still fails honestly in the accessor.
      sig { override.returns(T::Boolean) }
      def staleness_exempt? = true

      sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).void }
      def call(args:, context:)
        @accessor_factory.call(context.project!.root).print_path(args.positionals)
      end
    end
  end
end

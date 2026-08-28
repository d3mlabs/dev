# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/command"
require "dev/deps/accessor"
require "dev/deps/cache"
require "dev/deps/lockfile"

module Dev
  module Builtins
    # `dev deps`: read-only lookups over the lockfile + content cache (e.g.
    # `dev deps path ficsit <mod> <platform>`).
    class DepsCommand < BuiltinCommand
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
            cache: Dev::Deps::Cache.new,
          )
        }
      )
        super()
        @accessor_factory = T.let(accessor_factory, AccessorFactory)
      end

      sig { override.returns(String) }
      def desc = "Inspect locked dependencies (e.g. deps path ficsit <mod> <platform>)"

      sig { override.returns(Command::Category) }
      def category = Command::Category::Lifecycle

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        @accessor_factory.call(context.project!.root).run(args)
      end
    end
  end
end

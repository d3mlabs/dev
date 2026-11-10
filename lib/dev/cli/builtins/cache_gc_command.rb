# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/cli/command"
require "dev/container_engine"
require "dev/deps/cache_gc"
require "dev/deps/lockfile"
require "dev/lifecycle"

module Dev
  module Cli
    module Builtins
      # `dev cache gc [--keep N] [--tool-caches]`: reclaim stale tree
      # versions, the engine's stale Linuxbrew prefix volumes, the tags of
      # the lock's images that the lock no longer names, and the snapshot
      # branches of remote dispatches older than the retention; with
      # `--tool-caches`, also drop the tools' download caches whole. A leaf
      # of the `cache` group.
      class CacheGcCommand < BuiltinCommand
        extend T::Sig

        KEEP_FLAG = "--keep"
        TOOL_CACHES_FLAG = "--tool-caches"

        # Builds the GC over a project's lockfile (per-call project root).
        CacheGcFactory = T.type_alias do
          T.proc.params(lockfile: Dev::Deps::Lockfile).returns(Dev::Deps::CacheGc)
        end

        # Builds the snapshot-branch namespace over a project's checkout
        # (per-call project root).
        SnapshotBranchesFactory = T.type_alias do
          T.proc.params(root: Pathname).returns(Dev::Lifecycle::SnapshotBranches)
        end

        sig { params(cache_gc_factory: CacheGcFactory, snapshot_branches_factory: SnapshotBranchesFactory).void }
        def initialize(
          cache_gc_factory: ->(lockfile) {
            Dev::Deps::CacheGc.new(lockfile:, engine: Dev::ContainerEngine.resolve)
          },
          snapshot_branches_factory: ->(root) {
            Dev::Lifecycle::SnapshotBranches.new(git: Dev::Lifecycle::Git.new(root:))
          }
        )
          super()
          @cache_gc_factory = cache_gc_factory
          @snapshot_branches_factory = snapshot_branches_factory
        end

        sig { override.returns(String) }
        def desc
          "Reclaim stale tree versions, build images, prefix volumes and snapshot branches (--keep N; --tool-caches drops the tools' caches)"
        end

        sig { override.returns(Command::Category) }
        def category
          Command::Category::Workflow
        end

        sig { override.returns(T::Array[Cli::Flag]) }
        def flags
          [Cli::Flag.new(KEEP_FLAG, takes_value: true), Cli::Flag.new(TOOL_CACHES_FLAG)]
        end

        # GC is maintenance over the cache, not a build: it reads the lockfile to
        # know what to keep and never needs the deps installed. It also runs as
        # cleanup after a failed `dev up` (CI's `if: always()` step), which is
        # exactly when the staleness guard would fire — and bury the real error
        # under "dependencies have never been installed".
        sig { override.returns(T::Boolean) }
        def staleness_exempt?
          true
        end

        sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).void }
        def call(args:, context:)
          project = context.project!
          gc = @cache_gc_factory.call(Dev::Deps::Lockfile.new(dir: project.root))
          gc.gc(
            keep: parse_keep(args), images: project.project_images.pinned,
            tool_caches: args.flag?(TOOL_CACHES_FLAG),
          )
          @snapshot_branches_factory.call(project.root).prune
        end

        private

        # Parse `--keep N` / `--keep=N`, defaulting to the tight tree
        # retention.
        #
        # @param args [Array<String>]
        # @return [Integer]
        sig { params(args: Cli::ParsedArgs).returns(Integer) }
        def parse_keep(args)
          keep = args.value(KEEP_FLAG)
          keep ? Integer(keep) : Dev::Deps::CacheGc::DEFAULT_KEEP
        end
      end
    end
  end
end

# typed: strict
# frozen_string_literal: true

require "dev/command"
require "dev/container_engine"
require "dev/deps/cache_gc"
require "dev/deps/lockfile"
require "dev/build_container"

module Dev
  module Builtins
    # `dev cache gc [--keep N] [--tool-caches]`: reclaim stale install-dir
    # versions and, when a build container is configured, its stale
    # content-tagged images; with `--tool-caches`, also drop the tools'
    # download caches whole. A leaf of the `cache` group.
    class CacheGcCommand < BuiltinCommand
      extend T::Sig

      KEEP_FLAG = "--keep"
      TOOL_CACHES_FLAG = "--tool-caches"

      # Builds the GC over a project's lockfile (per-call project root).
      CacheGcFactory = T.type_alias do
        T.proc.params(lockfile: Dev::Deps::Lockfile).returns(Dev::Deps::CacheGc)
      end

      sig { params(cache_gc_factory: CacheGcFactory).void }
      def initialize(
        cache_gc_factory: ->(lockfile) {
          Dev::Deps::CacheGc.new(lockfile:, engine: Dev::ContainerEngine.resolve)
        }
      )
        super()
        @cache_gc_factory = cache_gc_factory
      end

      sig { override.returns(String) }
      def desc = "Reclaim stale install-dir versions and build images (--keep N; --tool-caches drops the tools' caches)"

      sig { override.returns(Command::Category) }
      def category = Command::Category::Workflow

      sig { override.returns(T::Array[Cli::Flag]) }
      def flags = [Cli::Flag.new(KEEP_FLAG, takes_value: true), Cli::Flag.new(TOOL_CACHES_FLAG)]

      # GC is maintenance over the cache, not a build: it reads the lockfile to
      # know what to keep and never needs the deps installed. It also runs as
      # cleanup after a failed `dev up` (CI's `if: always()` step), which is
      # exactly when the staleness guard would fire — and bury the real error
      # under "dependencies have never been installed".
      sig { override.returns(T::Boolean) }
      def staleness_exempt? = true

      sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).void }
      def call(args:, context:)
        project = context.project!
        gc = @cache_gc_factory.call(Dev::Deps::Lockfile.new(dir: project.root))
        # The build container config (when present) lets GC also prune stale
        # content-tagged images while protecting the live tag.
        image_ref = T.let(nil, T.nilable(String))
        live_tag = T.let(nil, T.nilable(String))
        if (cfg = project.build_container)
          image_ref = cfg.image_ref
          live_tag = BuildContainer.image_with_tag(cfg, project_root: project.root)
        end
        gc.gc(
          keep: parse_keep(args), image_ref: image_ref, live_tag: live_tag,
          tool_caches: args.flag?(TOOL_CACHES_FLAG),
        )
      end

      private

      # Parse `--keep N` / `--keep=N`, defaulting to the tight install-dir
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

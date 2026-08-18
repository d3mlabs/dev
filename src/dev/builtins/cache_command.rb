# typed: strict
# frozen_string_literal: true

require "dev/cli/flag_parser"
require "dev/command"
require "dev/deps/cache_gc"
require "dev/deps/lockfile"
require "build_container"

module Dev
  module Builtins
    # `dev cache gc [--keep N]`: reclaim stale install-dir versions and, when
    # a build container is configured, its stale content-tagged images.
    class CacheCommand < BuiltinCommand
      extend T::Sig

      # Builds the GC over a project's lockfile (per-call project root).
      CacheGcFactory = T.type_alias do
        T.proc.params(lockfile: Dev::Deps::Lockfile).returns(Dev::Deps::CacheGc)
      end

      sig { params(cache_gc_factory: CacheGcFactory, flag_parser: Cli::FlagParser).void }
      def initialize(
        cache_gc_factory: ->(lockfile) { Dev::Deps::CacheGc.new(lockfile:) },
        flag_parser: Cli::FlagParser.new
      )
        super()
        @cache_gc_factory = T.let(cache_gc_factory, CacheGcFactory)
        @flag_parser = T.let(flag_parser, Cli::FlagParser)
      end

      sig { override.returns(String) }
      def desc = "Manage host caches (e.g. cache gc --keep 2)"

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        subcommand, *rest = args
        raise ArgumentError, "usage: dev cache gc [--keep N]" unless subcommand == "gc"

        gc = @cache_gc_factory.call(Dev::Deps::Lockfile.new(dir: context.project_root))
        # The build container config (when present) lets GC also prune stale
        # content-tagged images while protecting the live tag.
        image_ref = T.let(nil, T.nilable(String))
        live_tag = T.let(nil, T.nilable(String))
        if (cfg = context.build_container)
          image_ref = cfg.image_ref
          live_tag = BuildContainer.image_with_tag(cfg, project_root: context.project_root)
        end
        gc.gc(keep: parse_keep(rest), image_ref: image_ref, live_tag: live_tag)
      end

      private

      # Parse `--keep N` / `--keep=N`, defaulting to the tight install-dir
      # retention.
      #
      # @param args [Array<String>]
      # @return [Integer]
      sig { params(args: T::Array[String]).returns(Integer) }
      def parse_keep(args)
        keep = @flag_parser.value(args, "--keep")
        keep ? Integer(keep) : Dev::Deps::CacheGc::DEFAULT_KEEP
      end
    end
  end
end

# frozen_string_literal: true

require "pathname"
require_relative "../settings"
require_relative "cache"
require_relative "synchronizer"

module Dev
  module Knowledge
    # Dispatch for `dev knowledge …` — the explicit surface over the machine
    # knowledge cache. Passive distribution rides dev's hook points (`dev up`
    # / `install-deps` / `dev plan`); these verbs are the manual override and
    # the inspection:
    #
    # - `sync`   — refresh the cache now (blocking, TTL bypassed), then link
    #              skills and re-render the invariants rule
    # - `status` — configured repo, cache location, age, and freshness
    #
    # RuntimeError subclasses throughout so the CLI boundary prints clean
    # `dev:` messages instead of backtraces.
    class Accessor
      class UsageError < RuntimeError; end

      USAGE = <<~USAGE.strip
        usage: dev knowledge <subcommand>
          dev knowledge sync      refresh the machine knowledge cache now (bypasses the TTL)
          dev knowledge status    cache location, age, and freshness
      USAGE

      # @param project_root [Pathname] the enclosing repo (invariants render
      #   target); the caller resolves it from the cwd
      # @param settings [Dev::Settings]
      # @param cache [Dev::Knowledge::Cache, nil] override for tests; defaults
      #   to a cache over the configured knowledge repo (nil when unconfigured)
      # @param synchronizer [Dev::Knowledge::Synchronizer, nil]
      def initialize(project_root:, settings: Dev::Settings.new, cache: nil, synchronizer: nil)
        @project_root = Pathname(project_root)
        @settings = settings
        repo = settings.knowledge_repo
        @cache = cache || (repo && Cache.new(repo: repo))
        @synchronizer = synchronizer || Synchronizer.new(settings: settings, cache: @cache)
      end

      # Dispatch a `dev knowledge …` invocation.
      #
      # @param args [Array<String>] argv after the "knowledge" command
      # @param out [IO] output stream
      # @return [void]
      # @raise [UsageError] on an unrecognized invocation
      def run(args, out: $stdout)
        case args
        when ["sync"] then sync(out:)
        when ["status"] then status(out:)
        else raise UsageError, USAGE
        end
      end

      private

      # @param out [IO]
      # @return [void]
      def sync(out:)
        @synchronizer.sync!(project_root: @project_root)
        out.puts "dev: knowledge cache synced from #{@settings.knowledge_repo} (#{@cache.dir})."
      end

      # @param out [IO]
      # @return [void]
      def status(out:)
        repo = @settings.knowledge_repo
        if repo.nil?
          out.puts "dev: no knowledge repo configured — add `knowledge_repo: <owner>/<repo>` " \
            "to #{@settings.config_path} (or set DEV_KNOWLEDGE_REPO)."
          return
        end

        out.puts "dev: knowledge repo: #{repo}"
        unless @cache.present?
          out.puts "dev: cache: #{@cache.dir} (not cloned yet — run `dev knowledge sync`)."
          return
        end

        ttl = @settings.knowledge_ttl
        freshness = @cache.stale?(ttl) ? "stale — the next dev hook refreshes it, or run `dev knowledge sync`" : "fresh"
        out.puts "dev: cache: #{@cache.dir}"
        out.puts "dev: last synced #{format_age(Time.now - @cache.synced_at)} ago (TTL #{format_age(ttl)}; #{freshness})."
      end

      # @param seconds [Numeric]
      # @return [String] a compact human age, e.g. "42s", "7m", "3h", "2d"
      def format_age(seconds)
        case seconds
        when 0...60 then "#{seconds.to_i}s"
        when 60...3600 then "#{(seconds / 60).to_i}m"
        when 3600...86_400 then "#{(seconds / 3600).to_i}h"
        else "#{(seconds / 86_400).to_i}d"
        end
      end
    end
  end
end

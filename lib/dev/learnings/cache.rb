# typed: strict
# frozen_string_literal: true

require "fileutils"
require "open3"
require "pathname"
require "sorbet-runtime"
require_relative "layout"

module Dev
  module Learnings
    # Machine-local git cache of the org knowledge repo, under
    # $XDG_DATA_HOME/dev/knowledge (~/.local/share/dev/knowledge).
    #
    # Two refresh shapes, both cheap (the knowledge repo is tiny):
    # `dev learnings sync` calls refresh (blocking, errors bubble), and hook
    # points call refresh_bounded — an inline pull capped by a short timeout,
    # so a hook distributes what it just fetched instead of what it found. On
    # timeout the pull keeps running detached and the current cache is served;
    # offline simply serves the cache. A hardcoded ~30s courtesy floor keeps
    # rapid-fire hooks (e.g. per-edit plan hooks) from pulling on every call —
    # deliberately a constant, not a setting.
    #
    # A "owner/repo" source clones through `gh` so the fetch rides the user's
    # gh auth (dev is public and carries no credentials of its own); any other
    # source (URL, local path) clones through git directly.
    class Cache
      extend T::Sig

      # `git clone` (via gh or git) of the knowledge repo failed.
      class KnowledgeCloneError < RuntimeError; end

      # `git pull` refreshing an existing cache failed.
      class KnowledgeFetchError < RuntimeError; end

      OWNER_REPO_PATTERN = %r{\A[\w.-]+/[\w.-]+\z}

      # How long a bounded refresh waits for the pull before detaching it and
      # serving the current cache.
      REFRESH_TIMEOUT_SECONDS = 2

      # Courtesy floor between bounded refreshes: within it, refresh_bounded
      # is a no-op. A constant, not a setting — the only cost it caps is a
      # subsecond no-op pull.
      REFRESH_FLOOR_SECONDS = 30

      # Poll cadence while waiting on a bounded refresh's child process.
      REFRESH_POLL_SECONDS = 0.05

      # @return [Pathname] the clone's location
      sig { returns(Pathname) }
      attr_reader :dir

      # @param repo [String] "owner/repo" (cloned via gh, the user's auth) or
      #   any git-clonable URL or local path
      # @param dir [Pathname, String, nil] override for tests; defaults to the
      #   XDG data location
      # @param refresh_timeout [Integer, Float] override for tests; how long a
      #   bounded refresh blocks before detaching
      # @param refresh_floor [Integer, Float] override for tests; minimum age
      #   before a bounded refresh pulls again
      sig do
        params(
          repo: String,
          dir: T.nilable(T.any(Pathname, String)),
          refresh_timeout: T.any(Integer, Float),
          refresh_floor: T.any(Integer, Float),
        ).void
      end
      def initialize(repo:, dir: nil, refresh_timeout: REFRESH_TIMEOUT_SECONDS, refresh_floor: REFRESH_FLOOR_SECONDS)
        @repo = repo
        @dir = T.let(Pathname(dir || default_dir), Pathname)
        @refresh_timeout = refresh_timeout
        @refresh_floor = refresh_floor
      end

      # @return [Boolean] whether the cache has been cloned
      sig { returns(T::Boolean) }
      def present?
        (@dir / ".git").exist?
      end

      # The org tier's layout inside the cache (Layout is the canonical
      # owner: the always-on index at the root, the on-demand skills corpus
      # beside it).

      # @return [Pathname] the on-demand skills corpus inside the cache
      sig { returns(Pathname) }
      def skills_dir
        Layout.org_skills_dir(@dir)
      end

      # @return [Pathname] the org learnings index inside the cache
      sig { returns(Pathname) }
      def index_file
        Layout.org_index_file(@dir)
      end

      # Blocking refresh: clone on first run, fast-forward pull after (the
      # cache never has local commits, so a pull is always a fast-forward —
      # and a cheap no-op when nothing changed upstream).
      #
      # @return [void]
      # @raise [KnowledgeCloneError] when the initial clone fails
      # @raise [KnowledgeFetchError] when the pull fails
      sig { void }
      def refresh
        if present?
          run_or_raise(pull_command, KnowledgeFetchError)
        else
          FileUtils.mkdir_p(@dir.dirname)
          run_or_raise(clone_command, KnowledgeCloneError)
        end
      end

      # Bounded refresh for hook points: pull (or first-clone) inline, waiting
      # up to the timeout so the calling hook distributes fresh content, then
      # detach and fall back to the current cache when the network is slower
      # than that. Within the courtesy floor of the last successful refresh it
      # is a no-op. Never raises — offline or a failed pull only means the
      # cache is served as-is, and the explicit `dev learnings sync` path
      # reports errors properly.
      #
      # @return [void]
      sig { void }
      def refresh_bounded
        return if refreshed_within_floor?

        FileUtils.mkdir_p(@dir.dirname)
        pid = T.unsafe(Process).spawn(*(present? ? pull_command : clone_command), out: File::NULL, err: File::NULL)
        wait_or_detach(pid)
      rescue SystemCallError => e
        $stderr.puts "dev: warning: could not start the knowledge repo cache refresh (#{e.message})."
      end

      # When the cache last talked to the remote: the fetch marker's mtime,
      # falling back to HEAD's (a fresh clone has no FETCH_HEAD yet).
      #
      # @return [Time, nil] nil when the cache has never been cloned
      sig { returns(T.nilable(Time)) }
      def synced_at
        marker = [@dir / ".git" / "FETCH_HEAD", @dir / ".git" / "HEAD"].find(&:exist?)
        marker&.mtime
      end

      private

      # @return [Boolean] whether the last successful refresh is inside the
      #   courtesy floor
      sig { returns(T::Boolean) }
      def refreshed_within_floor?
        at = synced_at
        !at.nil? && (Time.now - at) <= @refresh_floor
      end

      # Wait for the refresh child up to the timeout; past it, detach so the
      # pull finishes in the background and the next hook serves its result.
      #
      # @param pid [Integer]
      # @return [void]
      sig { params(pid: Integer).void }
      def wait_or_detach(pid)
        deadline = Time.now + @refresh_timeout
        until Process.waitpid(pid, Process::WNOHANG)
          if Time.now >= deadline
            Process.detach(pid)
            return
          end

          sleep(REFRESH_POLL_SECONDS)
        end
      end

      # @param command [Array<String>]
      # @param error_class [Class<RuntimeError>]
      # @return [void]
      # @raise [RuntimeError] error_class when the command fails
      sig { params(command: T::Array[String], error_class: T.class_of(RuntimeError)).void }
      def run_or_raise(command, error_class)
        _out, err, status = T.unsafe(Open3).capture3(*command)
        raise error_class, "#{command.first} failed for #{@repo}: #{err.strip}" unless status.success?
      end

      # @return [Array<String>]
      sig { returns(T::Array[String]) }
      def clone_command
        if @repo.match?(OWNER_REPO_PATTERN)
          ["gh", "repo", "clone", @repo, @dir.to_s, "--", "--quiet"]
        else
          ["git", "clone", "--quiet", @repo, @dir.to_s]
        end
      end

      # @return [Array<String>]
      sig { returns(T::Array[String]) }
      def pull_command
        ["git", "-C", @dir.to_s, "pull", "--ff-only", "--quiet"]
      end

      # @return [String]
      sig { returns(String) }
      def default_dir
        data_home = ENV.fetch("XDG_DATA_HOME", File.join(Dir.home, ".local", "share"))
        File.join(data_home, "dev", "knowledge")
      end
    end
  end
end

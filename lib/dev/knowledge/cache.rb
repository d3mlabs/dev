# frozen_string_literal: true

require "fileutils"
require "open3"
require "pathname"

module Dev
  module Knowledge
    # Machine-local git cache of the org knowledge repo, under
    # $XDG_DATA_HOME/dev/knowledge (~/.local/share/dev/knowledge).
    #
    # Two frequencies, no network on the hot path: hooks call refresh_async
    # when the TTL has lapsed (a detached child process; the calling command
    # never blocks on the network), and `dev knowledge sync` calls refresh
    # (blocking, TTL bypassed). Offline simply serves the cache; the
    # staleness ceiling is the TTL.
    #
    # A "owner/repo" source clones through `gh` so the fetch rides the user's
    # gh auth (dev is public and carries no credentials of its own); any other
    # source (URL, local path) clones through git directly.
    class Cache
      # `git clone` (via gh or git) of the knowledge repo failed.
      class KnowledgeCloneError < RuntimeError; end

      # `git pull` refreshing an existing cache failed.
      class KnowledgeFetchError < RuntimeError; end

      # Layout of the knowledge repo (see d3mlabs/knowledge's README): the
      # always-on index at the root, the on-demand skills corpus beside it.
      INDEX_FILE = "index.md"
      SKILLS_SUBDIR = "skills"

      OWNER_REPO_PATTERN = %r{\A[\w.-]+/[\w.-]+\z}

      # @return [Pathname] the clone's location
      attr_reader :dir

      # @param repo [String] "owner/repo" (cloned via gh, the user's auth) or
      #   any git-clonable URL or local path
      # @param dir [Pathname, String, nil] override for tests; defaults to the
      #   XDG data location
      def initialize(repo:, dir: nil)
        @repo = repo
        @dir = Pathname(dir || default_dir)
      end

      # @return [Boolean] whether the cache has been cloned
      def present?
        (@dir / ".git").exist?
      end

      # @return [Pathname] the on-demand skills corpus inside the cache
      def skills_dir
        @dir / SKILLS_SUBDIR
      end

      # @return [Pathname] the org learnings index inside the cache
      def index_file
        @dir / INDEX_FILE
      end

      # Blocking refresh: clone on first run, fast-forward pull after (the
      # cache never has local commits, so a pull is always a fast-forward —
      # and a cheap no-op when nothing changed upstream).
      #
      # @return [void]
      # @raise [KnowledgeCloneError] when the initial clone fails
      # @raise [KnowledgeFetchError] when the pull fails
      def refresh
        if present?
          run_or_raise(pull_command, KnowledgeFetchError)
        else
          FileUtils.mkdir_p(@dir.dirname)
          run_or_raise(clone_command, KnowledgeCloneError)
        end
      end

      # Fire-and-forget refresh in a detached child process, so hook points
      # never block on the network. A first-run clone is async too: this
      # command renders nothing, the next one serves the fresh cache. Never
      # raises — a failed background refresh only extends staleness, and the
      # explicit `dev knowledge sync` path reports errors properly.
      #
      # @return [void]
      def refresh_async
        FileUtils.mkdir_p(@dir.dirname)
        pid = Process.spawn(*(present? ? pull_command : clone_command), out: File::NULL, err: File::NULL)
        Process.detach(pid)
        nil
      rescue SystemCallError => e
        $stderr.puts "dev: warning: could not start the knowledge cache refresh (#{e.message})."
      end

      # When the cache last talked to the remote: the fetch marker's mtime,
      # falling back to HEAD's (a fresh clone has no FETCH_HEAD yet).
      #
      # @return [Time, nil] nil when the cache has never been cloned
      def synced_at
        marker = [@dir / ".git" / "FETCH_HEAD", @dir / ".git" / "HEAD"].find(&:exist?)
        marker&.mtime
      end

      # @param ttl_seconds [Integer] staleness ceiling
      # @return [Boolean] true when never synced or older than the TTL
      def stale?(ttl_seconds)
        at = synced_at
        at.nil? || (Time.now - at) > ttl_seconds
      end

      private

      # @param command [Array<String>]
      # @param error_class [Class<RuntimeError>]
      # @return [void]
      # @raise [RuntimeError] error_class when the command fails
      def run_or_raise(command, error_class)
        _out, err, status = Open3.capture3(*command)
        raise error_class, "#{command.first} failed for #{@repo}: #{err.strip}" unless status.success?
      end

      # @return [Array<String>]
      def clone_command
        if @repo.match?(OWNER_REPO_PATTERN)
          ["gh", "repo", "clone", @repo, @dir.to_s, "--", "--quiet"]
        else
          ["git", "clone", "--quiet", @repo, @dir.to_s]
        end
      end

      # @return [Array<String>]
      def pull_command
        ["git", "-C", @dir.to_s, "pull", "--ff-only", "--quiet"]
      end

      # @return [String]
      def default_dir
        data_home = ENV.fetch("XDG_DATA_HOME", File.join(Dir.home, ".local", "share"))
        File.join(data_home, "dev", "knowledge")
      end
    end
  end
end

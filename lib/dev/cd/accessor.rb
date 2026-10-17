# typed: strict
# frozen_string_literal: true

require "pathname"
require "stringio"
require "dev/cd/repo_discovery"
require "dev/cd/matcher"
require "dev/cd/hook_installer"

module Dev
  module Cd
    # Dispatch for `dev cd …` — the Ruby half of the directory jumper.
    #
    # The human command is `dev cd <query>`, handled by the installed shell
    # wrapper; this class serves the wrapper's machine contracts (hidden
    # plumbing, not user surfaces): #resolve prints exactly one absolute
    # repo path on stdout, #candidates prints ranked candidates one per
    # line. One public method per mode; the `cd` builtin picks the mode
    # from argv.
    #
    # A bare `dev cd …` reaching this process means the wrapper isn't active
    # in the calling shell (a child process cannot change the parent's cwd),
    # so instead of printing a path that does nothing #explain_missing_hook
    # self-heals the hook and explains how to activate it.
    class Accessor
      extend T::Sig

      # `dev cd` ran without the shell wrapper being active.
      class ShellHookInactiveError < RuntimeError; end

      # A plumbing mode was invoked with the wrong arguments.
      class UsageError < RuntimeError; end

      # @param root [String, Pathname] search root (default: $DEV_CD_ROOT, else ~/src)
      # @param hook_installer [Dev::Cd::HookInstaller]
      sig { params(root: T.any(String, Pathname), hook_installer: HookInstaller).void }
      def initialize(root: ENV["DEV_CD_ROOT"] || (Pathname(Dir.home) / "src"),
                     hook_installer: HookInstaller.new)
        @discovery = T.let(RepoDiscovery.new(root: root), RepoDiscovery)
        @hook_installer = hook_installer
      end

      # Resolve the query to one absolute path (the wrapper `builtin cd`s
      # into it). Also self-heals the hook: a user who never ran `dev up`
      # still ends up with a working wrapper for their next shell.
      #
      # @param query [String] the fuzzy repo name
      # @param out [IO, StringIO] stdout (the path only)
      # @param err [IO, StringIO] stderr (diagnostics and hints)
      # @return [void]
      # @raise [Matcher::RepoNotFoundError] when nothing matches
      # @raise [Matcher::AmbiguousRepoError] when several repos match
      sig { params(query: String, out: T.any(IO, StringIO), err: T.any(IO, StringIO)).void }
      def resolve(query, out:, err:)
        if @hook_installer.ensure_installed == :added
          err.puts "dev: shell hook updated — open a new shell to refresh it."
        end
        out.puts matcher.resolve(query).path
      end

      # Print ranked candidates for a partial query, one per line, each at
      # its shortest-unique depth. An empty query lists everything —
      # ambiguity is the point here, not an error.
      #
      # @param query [String] the partial repo name; "" for all
      # @param out [IO, StringIO]
      # @return [void]
      sig { params(query: String, out: T.any(IO, StringIO)).void }
      def candidates(query, out:)
        matcher.candidates(query).each { |candidate| out.puts(candidate) }
      end

      # Bare `dev cd` reached the Ruby process: install the hook and tell the
      # user how to activate it, then fail (this process cannot cd for them).
      #
      # @param err [IO, StringIO]
      # @return [void]
      # @raise [ShellHookInactiveError] always
      sig { params(err: T.any(IO, StringIO)).void }
      def explain_missing_hook(err:)
        case @hook_installer.ensure_installed
        when :added
          err.puts "dev: shell hook installed — open a new shell (or source your shell RC), then run `dev cd <repo>` again."
        when :already_present
          err.puts "dev: the dev cd shell hook is installed but not active in this shell — open a new shell (or source your shell RC)."
        else
          err.puts "dev: `dev cd` needs a shell hook, and your shell is unsupported (supported: zsh, bash, fish)."
        end
        raise ShellHookInactiveError, "the dev cd shell hook is not active"
      end

      private

      # A matcher over a fresh discovery walk. Rebuilt per command: discovery
      # is fast by construction (pruned, depth-bounded) and each invocation
      # must see the current state of the checkout tree.
      #
      # @return [Dev::Cd::Matcher]
      sig { returns(Matcher) }
      def matcher
        Matcher.new(repos: @discovery.repos)
      end
    end
  end
end

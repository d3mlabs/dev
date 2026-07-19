# frozen_string_literal: true

require "pathname"
require "dev/cd/repo_discovery"
require "dev/cd/matcher"
require "dev/cd/hook_installer"

module Dev
  module Cd
    # Dispatch for `dev cd …` — the Ruby half of the directory jumper.
    #
    # The human command is `dev cd <query>`, handled by the installed shell
    # wrapper; this class serves the wrapper's machine contracts (hidden
    # plumbing, not user surfaces):
    #
    # - `--resolve <query>`:    print exactly one absolute repo path on stdout
    # - `--candidates [<q>]`:   print ranked candidates, one per line
    #
    # A bare `dev cd …` reaching this process means the wrapper isn't active
    # in the calling shell (a child process cannot change the parent's cwd),
    # so instead of printing a path that does nothing it self-heals the hook
    # and explains how to activate it.
    class Accessor
      # `dev cd` ran without the shell wrapper being active.
      class ShellHookInactiveError < RuntimeError; end

      # A plumbing flag was invoked with the wrong arguments.
      class UsageError < RuntimeError; end

      # @param root [String, Pathname] search root (default: $DEV_CD_ROOT, else ~/src)
      # @param hook_installer [Dev::Cd::HookInstaller]
      def initialize(root: ENV["DEV_CD_ROOT"] || (Pathname(Dir.home) / "src"),
                     hook_installer: HookInstaller.new)
        @discovery = RepoDiscovery.new(root: root)
        @hook_installer = hook_installer
      end

      # Dispatch a `dev cd …` invocation.
      #
      # @param args [Array<String>] argv after the "cd" command
      # @param out [IO] stdout (the machine-readable payload only)
      # @param err [IO] stderr (diagnostics and hints)
      # @raise [UsageError] on malformed plumbing invocations
      # @raise [ShellHookInactiveError] for bare invocations without the hook
      # @raise [Matcher::RepoNotFoundError] when --resolve matches nothing
      # @raise [Matcher::AmbiguousRepoError] when --resolve matches several repos
      def run(args, out: $stdout, err: $stderr)
        flag, *rest = args
        case flag
        when "--resolve" then resolve(rest, out:, err:)
        when "--candidates" then candidates(rest, out:)
        else explain_missing_hook(err:)
        end
      end

      private

      # Resolve the query to one absolute path (the wrapper `builtin cd`s
      # into it). Also self-heals the hook: a user who never ran `dev up`
      # still ends up with a working wrapper for their next shell.
      #
      # @param args [Array<String>]
      # @param out [IO]
      # @param err [IO]
      # @return [void]
      # @raise [UsageError] unless exactly one query argument is given
      def resolve(args, out:, err:)
        raise UsageError, "usage: dev cd <query>" unless args.size == 1

        if @hook_installer.ensure_installed == :added
          err.puts "dev: shell hook updated — open a new shell to refresh it."
        end
        out.puts matcher.resolve(args.fetch(0)).path
      end

      # Print ranked candidates for a partial query, one per line, each at
      # its shortest-unique depth. An empty query lists everything —
      # ambiguity is the point here, not an error.
      #
      # @param args [Array<String>]
      # @param out [IO]
      # @return [void]
      # @raise [UsageError] when more than one query argument is given
      def candidates(args, out:)
        raise UsageError, "usage: dev cd --candidates [<query>]" if args.size > 1

        matcher.candidates(args.fetch(0, "")).each { |candidate| out.puts(candidate) }
      end

      # Bare `dev cd` reached the Ruby process: install the hook and tell the
      # user how to activate it, then fail (this process cannot cd for them).
      #
      # @param err [IO]
      # @return [void]
      # @raise [ShellHookInactiveError] always
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

      # A matcher over a fresh discovery walk. Rebuilt per command: discovery
      # is fast by construction (pruned, depth-bounded) and each invocation
      # must see the current state of the checkout tree.
      #
      # @return [Dev::Cd::Matcher]
      def matcher
        Matcher.new(repos: @discovery.repos)
      end
    end
  end
end

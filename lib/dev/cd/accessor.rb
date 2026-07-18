# frozen_string_literal: true

require "dev/cd/matcher"
require "dev/cd/workspace"

module Dev
  module Cd
    # CLI surface for the global `dev cd` command (no `dev.yml` required).
    #
    # User-facing form is `dev cd <query>` (via the shell hook installed by
    # `dev up`). `--resolve` and `--complete` are machine interfaces for that
    # hook — not day-to-day flags — so the hook can print a path / candidates
    # and then `builtin cd` (or feed the completer).
    class Accessor
      class UsageError < StandardError; end

      USAGE = <<~USAGE.strip
        usage: dev cd <query>
               dev cd --resolve <query>     (shell hook / scripting)
               dev cd --complete [<prefix>] (shell tab completion)
        Jump into a local checkout under DEV_CD_ROOT (default ~/src).
        Requires the shell hook so the current shell can change directory — see README.
      USAGE

      # @param matcher [Dev::Cd::Matcher, nil]
      # @param workspace [Dev::Cd::Workspace, nil]
      def initialize(matcher: nil, workspace: nil)
        @workspace = workspace || Workspace.new
        @matcher = matcher || Matcher.new(workspace: @workspace)
      end

      # Dispatch a `dev cd …` invocation.
      #
      # @param args [Array<String>] argv after the "cd" command
      # @param out [IO] stdout (resolved path / completion candidates)
      # @param err [IO] stderr (diagnostics)
      # @return [Integer] process exit status
      def run(args, out: $stdout, err: $stderr)
        case args[0]
        when "--resolve"
          resolve(args[1..], out:)
        when "--complete"
          complete(args[1..], out:)
        when nil, "--help", "-h"
          err.puts USAGE
          1
        else
          # Bare `dev cd <query>` (no shell hook): resolve for scripting.
          # A real directory change requires the shell function in the RC.
          resolve(args, out:)
        end
      rescue Matcher::RepoNotFoundError, Matcher::AmbiguousRepoError, UsageError => e
        err.puts e.message
        1
      end

      private

      # @param args [Array<String>]
      # @param out [IO]
      # @return [Integer]
      def resolve(args, out:)
        query = args.join(" ")
        raise UsageError, USAGE if query.empty?

        path = @matcher.resolve(query)
        out.puts(path)
        0
      end

      # @param args [Array<String>]
      # @param out [IO]
      # @return [Integer]
      def complete(args, out:)
        prefix = args[0] || ""
        @matcher.complete(prefix).each { |candidate| out.puts(candidate) }
        0
      end
    end
  end
end

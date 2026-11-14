# typed: strict
# frozen_string_literal: true

require "open3"
require "pathname"
require "dev/terminal_owner"
require_relative "shell"

module Dev
  module Lifecycle
    # The gh CLI boundary of the lifecycle's forge reads and writes. Every
    # call goes through one of two methods over one checkout, so gh
    # resolves the repo from the checkout's `origin` and uses the auth it
    # holds. Payloads go through stdin so a body never hits argv. `capture`
    # is for an answer dev reads; `stream` for a command whose output is
    # the operator's to watch and whose exit is the only thing dev reads.
    #
    # The one place gh is spawned by the lifecycle, and so the one thing a
    # test hands a fake for.
    class Gh
      extend T::Sig

      # gh exited nonzero; the message carries the argv and gh's stderr.
      class CommandFailedError < RuntimeError; end

      # No gh on PATH.
      class GhMissingError < RuntimeError; end

      Argv = T.type_alias { T::Array[String] }

      # What `capture` spawns gh under: colour off, whatever the operator
      # forced. gh honours CLICOLOR_FORCE and GH_FORCE_TTY on a pipe too and
      # would colourise the JSON dev reads. `stream` is the operator's
      # terminal and leaves their preference alone.
      CAPTURE_ENV = T.let({ "CLICOLOR_FORCE" => nil, "GH_FORCE_TTY" => nil, "NO_COLOR" => "1" }.freeze, T::Hash[String, T.nilable(String)])

      # @return [Pathname] the checkout every call runs in
      sig { returns(Pathname) }
      attr_reader :root

      # @param root [Pathname] the checkout gh resolves the repo from
      sig { params(root: Pathname).void }
      def initialize(root:)
        @root = root
      end

      # Run one gh command with dev's own stdout and stderr, and wait for
      # it: what the operator sees is gh's, what dev reads is the exit.
      #
      # @param argv [Array<String>] gh's arguments
      # @return [void]
      # @raise [CommandFailedError] the message carries the argv; gh already said why
      # @raise [GhMissingError]
      sig { params(argv: Argv).void }
      def stream(argv)
        # The terminal is gh's for output only: a watch never asks anything,
        # and a child left reading dev's stdin would wait on it. Gh's
        # all the same, so never under a spinner (TerminalOwner).
        TerminalOwner.claim!("`gh #{argv.join(" ")}`")
        pid = T.unsafe(Process).spawn("gh", *argv, chdir: @root.to_s, in: File::NULL)
        _pid, status = Process.wait2(pid)
        return if T.must(status).success?

        raise CommandFailedError, "gh #{argv.join(" ")} failed in #{@root} (#{Shell.describe(T.must(status))})"
      rescue Errno::ENOENT
        raise GhMissingError, "gh not found on PATH"
      end

      # Run one gh command and return what it printed — a machine answer,
      # so gh runs with colour off (CAPTURE_ENV).
      #
      # @param argv [Array<String>] gh's arguments
      # @param stdin [String, nil] a body piped to gh's stdin
      # @return [String] stdout, as printed
      # @raise [CommandFailedError]
      # @raise [GhMissingError]
      sig { params(argv: Argv, stdin: T.nilable(String)).returns(String) }
      def capture(argv, stdin: nil)
        out, err, status = T.unsafe(Open3).capture3(CAPTURE_ENV, "gh", *argv, stdin_data: stdin, chdir: @root.to_s)
        raise CommandFailedError, "gh #{argv.join(" ")} failed in #{@root}: #{err.strip}" unless status.success?

        out
      rescue Errno::ENOENT
        raise GhMissingError, "gh not found on PATH"
      end
    end
  end
end

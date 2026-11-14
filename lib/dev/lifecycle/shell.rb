# typed: strict
# frozen_string_literal: true

require "open3"
require "pathname"
require "dev/terminal_owner"

module Dev
  module Lifecycle
    # The process boundary of the lifecycle's tool invocations: a target's
    # `build:`/`package:` script at the project root, and the archive
    # pipelines (`tar | zstd | split`). Always spawn-and-wait, since a stage
    # has work after its seam. Returns the child's status so the caller's
    # error can carry the exit code.
    #
    # Every child inherits dev's stdio, so none may run under a spinner:
    # TerminalOwner refuses the spawn there and the caller uses `ui.step`.
    class Shell
      extend T::Sig

      # The child never started: the executable is missing, or the working
      # directory does not exist.
      class SpawnError < RuntimeError; end

      Argv = T.type_alias { T::Array[String] }

      class << self
        extend T::Sig

        # How a finished child ended, for an error message: its exit code,
        # or the signal that killed it.
        #
        # @param status [Process::Status]
        # @return [String] "exited 2" / "was killed by signal 9"
        sig { params(status: Process::Status).returns(String) }
        def describe(status)
          status.signaled? ? "was killed by signal #{status.termsig}" : "exited #{status.exitstatus}"
        end
      end

      # Run one command and wait for it.
      #
      # @param argv [Array<String>] the program and its arguments, never a shell string
      # @param chdir [Pathname] the child's working directory
      # @param env [Hash{String => String}] variables added to dev's own
      # @return [Process::Status]
      # @raise [SpawnError]
      sig { params(argv: Argv, chdir: Pathname, env: T::Hash[String, String]).returns(Process::Status) }
      def run(argv, chdir:, env: {})
        TerminalOwner.claim!("`#{argv.join(" ")}`")
        pid = T.unsafe(Process).spawn(env, *argv, chdir: chdir.to_s)
        _pid, status = Process.wait2(pid)
        T.must(status)
      rescue SystemCallError => e
        raise SpawnError, "could not run #{argv.first.inspect} in #{chdir}: #{e.message}"
      end

      # Run a pipeline — each command's stdout feeding the next's stdin —
      # and wait for every stage.
      #
      # @param commands [Array<Array<String>>] the stages, upstream first
      # @param chdir [Pathname] every stage's working directory
      # @return [Array<Process::Status>] one per stage, in pipeline order
      # @raise [SpawnError]
      sig { params(commands: T::Array[Argv], chdir: Pathname).returns(T::Array[Process::Status]) }
      def pipeline(commands, chdir:)
        TerminalOwner.claim!("`#{commands.map { |argv| argv.first.to_s }.join(" | ")}`")
        T.unsafe(Open3).pipeline(*commands, chdir: chdir.to_s)
      rescue SystemCallError => e
        raise SpawnError, "could not run #{commands.map { |argv| argv.first.inspect }.join(" | ")} in #{chdir}: #{e.message}"
      end
    end
  end
end

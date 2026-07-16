# frozen_string_literal: true

require "open3"

module Dev
  module Plan
    # Thin wrapper over the external CLIs `dev plan` drives (gh, git). Mirrors
    # Dev::RunnerSetup::Executor: the one injectable boundary so orchestration
    # is testable without real subprocesses.
    class Executor
      # @param argv [Array<String>] command and arguments
      # @param stdin [String, nil] data piped to the subprocess (e.g. a JSON
      #   payload for `gh api --input -`)
      # @return [Array(String, String, Boolean)] stdout, stderr, success?
      def capture(*argv, stdin: nil)
        out, err, status =
          if stdin
            Open3.capture3(*argv, stdin_data: stdin)
          else
            Open3.capture3(*argv)
          end
        [out, err, status.success?]
      rescue Errno::ENOENT => e
        ["", e.message, false]
      end
    end
  end
end

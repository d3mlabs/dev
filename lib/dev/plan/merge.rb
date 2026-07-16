# frozen_string_literal: true

require "tmpdir"

module Dev
  module Plan
    # 3-way merge of plan bodies via `git merge-file` (diff3), fed the base
    # copy recorded at last sync. Pure function over strings; the temp files
    # exist only because git merge-file works on paths.
    module Merge
      Result = Struct.new(:content, :conflicts, keyword_init: true) do
        def conflicts? = conflicts
      end

      module_function

      # @param local [String] the local plan body
      # @param base [String] the body at last sync (common ancestor)
      # @param remote [String] the current issue body
      # @param executor [Dev::Plan::Executor]
      # @return [Result] merged content, with conflict markers when both sides
      #   changed the same lines
      def three_way(local:, base:, remote:, executor: Executor.new)
        Dir.mktmpdir("ai-flow-merge-") do |dir|
          local_path = File.join(dir, "local")
          base_path = File.join(dir, "base")
          remote_path = File.join(dir, "remote")
          File.write(local_path, local)
          File.write(base_path, base)
          File.write(remote_path, remote)

          # git merge-file exits non-zero for the conflict count, so `ok` can't
          # distinguish "conflicts" from "failure" — the marker scan does.
          out, err, ok = executor.capture(
            "git", "merge-file", "-p", "--diff3",
            "-L", "local", "-L", "base", "-L", "remote",
            local_path, base_path, remote_path
          )
          conflicts = out.include?("<<<<<<<")
          raise Workspace::Error, "git merge-file failed: #{err.strip}" if !ok && !conflicts

          Result.new(content: out, conflicts: conflicts)
        end
      end
    end
  end
end

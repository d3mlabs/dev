# frozen_string_literal: true

require "fileutils"

module Dev
  module Plan
    # The base copy of an issue body at last sync, kept under
    # ~/.local/state/ai-flow/<owner>-<repo>-<n>.md. `synced_at` vs `updated_at`
    # detects divergence; this common-ancestor text is what makes a 3-way merge
    # possible when both sides changed (see the plan's data-model rationale).
    class MergeBase
      # @param state_dir [String, nil] override for tests; defaults to
      #   $XDG_STATE_HOME/ai-flow (~/.local/state/ai-flow)
      def initialize(state_dir: nil)
        @state_dir = state_dir || default_state_dir
      end

      # @param owner_repo [String] "owner/repo"
      # @param number [Integer]
      # @return [String, nil] the base body, or nil when no sync recorded
      def read(owner_repo, number)
        path = path_for(owner_repo, number)
        File.exist?(path) ? File.read(path) : nil
      end

      # @param owner_repo [String] "owner/repo"
      # @param number [Integer]
      # @param body [String]
      # @return [void]
      def write(owner_repo, number, body)
        FileUtils.mkdir_p(@state_dir)
        File.write(path_for(owner_repo, number), body)
      end

      # @param owner_repo [String] "owner/repo"
      # @param number [Integer]
      # @return [String]
      def path_for(owner_repo, number)
        File.join(@state_dir, "#{owner_repo.tr("/", "-")}-#{number}.md")
      end

      private

      # @return [String]
      def default_state_dir
        state_home = ENV.fetch("XDG_STATE_HOME", File.join(Dir.home, ".local", "state"))
        File.join(state_home, "ai-flow")
      end
    end
  end
end

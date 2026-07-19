# frozen_string_literal: true

require "pathname"
require "dev/cd/repo"

module Dev
  module Cd
    # Recursive discovery of git checkouts under a search root.
    #
    # A candidate is any directory containing a `.git` entry — directory or
    # file, so worktree checkouts count. The walk prunes at each hit (never
    # descends into a repo) and bounds depth, so it stays fast by construction
    # on the conventional `root/github.com/<org>/<repo>` layout.
    class RepoDiscovery
      # Deep enough for host/org/repo plus one nesting level of grouping dirs.
      MAX_DEPTH = 4

      # @param root [String, Pathname] the search root (e.g. $DEV_CD_ROOT)
      def initialize(root:)
        @root = Pathname(root).expand_path
      end

      # All git repos under the root, sorted by path for deterministic output.
      #
      # @return [Array<Dev::Cd::Repo>]
      def repos
        return [] unless @root.directory?

        found = []
        walk(@root, [], found)
        found.sort_by { |repo| repo.path.to_s }
      end

      private

      # Depth-first walk collecting repos, pruning at `.git` entries.
      #
      # @param dir [Pathname] directory being visited
      # @param segments [Array<String>] path segments from the root to dir
      # @param found [Array<Dev::Cd::Repo>] accumulator
      # @return [void]
      def walk(dir, segments, found)
        if !segments.empty? && (dir / ".git").exist?
          found << Repo.new(path: dir, segments: segments)
          return
        end
        return if segments.size >= MAX_DEPTH

        dir.children.each do |child|
          next unless child.directory? && !child.symlink?
          next if child.basename.to_s.start_with?(".")

          walk(child, segments + [child.basename.to_s], found)
        end
      rescue SystemCallError
        # Unreadable directories (permissions) are skipped, not fatal.
      end
    end
  end
end

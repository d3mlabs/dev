# typed: strict
# frozen_string_literal: true

require "fileutils"
require "pathname"
require "sorbet-runtime"
require_relative "layout"

module Dev
  module Learnings
    # Materializes the canonical learnings scaffold — Layout owns the paths
    # and templates, this class only writes them. The scaffold is
    # write-once-committed: it seeds an empty index that humans and capture
    # passes own afterward, so an existing index is never touched (the typed
    # error lets the CLI report the no-op cleanly).
    #
    # Stateless: one reusable instance scaffolds any root.
    class Scaffolder
      extend T::Sig

      # The tier's index already exists at the target root — the scaffold is
      # write-once and never overwrites a committed index.
      class IndexAlreadyExistsError < RuntimeError; end

      # Keeps the scaffolded (empty) org skills corpus commitable — git does
      # not track empty directories.
      GITKEEP_FILENAME = ".gitkeep"

      # Write the empty repo-tier index into a participating repo.
      #
      # @param repo_root [Pathname, String] the repo's root
      # @return [void]
      # @raise [IndexAlreadyExistsError] when the repo already has an index
      sig { params(repo_root: T.any(Pathname, String)).void }
      def scaffold_repo(repo_root)
        write_index(Layout.repo_index_file(repo_root), Layout::REPO_INDEX_SCAFFOLD)
      end

      # Write the knowledge-repo layout (index plus the skills corpus
      # directory) into an org's knowledge repo checkout.
      #
      # @param org_root [Pathname, String] the knowledge repo's root
      # @return [void]
      # @raise [IndexAlreadyExistsError] when the checkout already has an index
      sig { params(org_root: T.any(Pathname, String)).void }
      def scaffold_org(org_root)
        write_index(Layout.org_index_file(org_root), Layout::ORG_INDEX_SCAFFOLD)
        skills_dir = Layout.org_skills_dir(org_root)
        FileUtils.mkdir_p(skills_dir)
        FileUtils.touch(skills_dir / GITKEEP_FILENAME)
      end

      private

      # @param index_file [Pathname]
      # @param scaffold [String] the tier's template
      # @return [void]
      # @raise [IndexAlreadyExistsError] when the index already exists
      sig { params(index_file: Pathname, scaffold: String).void }
      def write_index(index_file, scaffold)
        if index_file.exist?
          raise IndexAlreadyExistsError,
            "#{index_file} already exists — the scaffold is write-once; edit or remove the index by hand instead."
        end

        FileUtils.mkdir_p(index_file.dirname)
        index_file.write(scaffold)
      end
    end
  end
end

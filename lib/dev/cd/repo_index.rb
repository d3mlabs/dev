# frozen_string_literal: true

require "find"
require "pathname"
require "dev/cd/repo"

module Dev
  module Cd
    # Discovers git checkouts under a search root (default `DEV_CD_ROOT` / `~/src`).
    # Primary layout is `$ROOT/github.com/<org>/<repo>`; other trees get a
    # best-effort parent/leaf org+name.
    class RepoIndex
      DEFAULT_ROOT = "~/src"
      ENV_ROOT = "DEV_CD_ROOT"

      # Resolve the search root from the environment (or the default).
      #
      # @param env [Hash] environment (injectable for tests)
      # @return [Pathname]
      def self.root(env: ENV)
        raw = env[ENV_ROOT]
        raw = DEFAULT_ROOT if raw.nil? || raw.empty?
        Pathname(raw).expand_path
      end

      # @param root [Pathname, String, nil] search root; defaults to {.root}
      def initialize(root: nil)
        @root = Pathname(root || self.class.root).expand_path
      end

      # @return [Pathname]
      attr_reader :root

      # Walk the search root for directories (or worktrees) that contain `.git`.
      #
      # @return [Array<Dev::Cd::Repo>] sorted by absolute path for stability
      def all
        return [] unless @root.directory?

        repos = []
        Find.find(@root.to_s) do |path_str|
          entry = Pathname(path_str)
          next unless git_dir?(entry)

          repos << build_repo(entry)
          # Do not descend into the checkout — treat the directory with `.git`
          # as the repo root (avoids nested `.git` under dependencies).
          Find.prune
        end
        repos.sort_by { |repo| repo.path.to_s }
      end

      private

      # @param entry [Pathname]
      # @return [Boolean]
      def git_dir?(entry)
        return false unless entry.directory?

        git = entry / ".git"
        git.directory? || git.file?
      end

      # Derive org/name from path segments under the search root.
      #
      # @param path [Pathname]
      # @return [Dev::Cd::Repo]
      def build_repo(path)
        relative = path.relative_path_from(@root)
        parts = relative.each_filename.to_a
        org, name = org_and_name(parts)
        Repo.new(path: path, org: org, name: name)
      end

      # Prefer `github.com/<org>/<repo>` layout; otherwise parent/leaf.
      #
      # @param parts [Array<String>] path segments relative to the search root
      # @return [Array(String, String)]
      def org_and_name(parts)
        if parts.length >= 3 && parts[0] == "github.com"
          [parts[-2], parts[-1]]
        elsif parts.length >= 2
          [parts[-2], parts[-1]]
        else
          ["", parts[-1] || ""]
        end
      end
    end
  end
end

# frozen_string_literal: true

require "open3"
require_relative "repository"
require_relative "dependency"

module Dev
  module Deps
    # Fetches git-hosted dependencies: tag → SHA, branch → SHA, or commit passthrough.
    #
    # Uses `git ls-remote` to resolve tags and branches to full SHAs.
    # 40-char hex commit SHAs pass through without network calls.
    # Git SHAs are identifiers, not integrity hashes — hash field is nil.
    class GitRepository < Repository
      class RefResolutionError < StandardError; end

      # Resolve a git dependency identifier to a pinned Dependency.
      #
      # @param id [Hash] must include "name", "repo", "integration", "group",
      #   and one of "tag" or "commit"
      # @return [Dependency] with version set to the resolved full SHA
      # @raise [RefResolutionError] if the ref cannot be resolved via ls-remote
      def fetch(id)
        repo_url = id["repo"]
        tag = id["tag"]
        commit = id["commit"]
        ref = commit || tag

        sha = resolve_ref(repo_url, ref)

        Dependency.new(
          name: id["name"],
          integration: id["integration"].to_sym,
          group: id["group"].to_sym,
          version: sha,
          hash: nil,
          metadata: { "repo" => repo_url },
        )
      end

      private

      # Resolve a git ref (tag, branch, or commit SHA) to a full 40-char SHA.
      #
      # Tries in order: passthrough for 40-char hex, ls-remote --tags, ls-remote branch.
      #
      # @param repo [String] git remote URL
      # @param ref  [String] tag name, branch name, or commit SHA
      # @return [String] full 40-char SHA
      # @raise [RefResolutionError] if no match found
      def resolve_ref(repo, ref)
        return ref if ref.to_s.length == 40 && ref.to_s.match?(/\A[0-9a-f]+\z/)

        out, _err, status = Open3.capture3("git", "ls-remote", "--tags", repo, ref.to_s)
        return out.lines.first.split.first if status.success? && !out.strip.empty?

        out, _err, status = Open3.capture3("git", "ls-remote", repo, "refs/heads/#{ref}")
        return out.lines.first.split.first if status.success? && !out.strip.empty?

        raise RefResolutionError, "Could not resolve ref '#{ref}' for #{repo}"
      end
    end
  end
end

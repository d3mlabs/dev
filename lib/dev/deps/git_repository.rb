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

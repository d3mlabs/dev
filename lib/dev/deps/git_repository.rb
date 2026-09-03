# typed: strict
# frozen_string_literal: true

require "open3"
require "sorbet-runtime"
require_relative "package"
require_relative "package_id"
require_relative "package_version"
require_relative "repository"

module Dev
  module Deps
    # Fetches git-hosted dependencies: tag → SHA, branch → SHA, or commit passthrough.
    #
    # Uses `git ls-remote` to resolve tags and branches to full SHAs.
    # 40-char hex commit SHAs pass through without network calls.
    # Git SHAs are identifiers, not integrity hashes — hash field is nil.
    class GitRepository < Repository
      extend T::Sig

      class RefResolutionError < PackageNotFoundError; end

      # Report a git dependency's universe: the declared ref resolved to its
      # full SHA, as a singleton.
      #
      # A git remote is not a version index — the filter's "commit" or "tag"
      # locates the one ref the declaration pins, and ls-remote turns it into
      # a SHA. SHAs are identifiers, not integrity digests, so the version
      # carries no digest.
      #
      # @param id [PackageId] source is the git remote URL
      # @param filter [Hash] locator: one of "commit" or "tag"
      # @return [Package] a singleton universe
      # @raise [RefResolutionError] if the ref cannot be resolved via ls-remote
      sig { override.params(id: PackageId, filter: T::Hash[String, T.untyped]).returns(Package) }
      def find(id, filter: {})
        repo_url = T.must(id.source)
        sha = resolve_ref(repo_url, filter["commit"] || filter["tag"])

        Package.new(
          id: id,
          versions: [PackageVersion.new(version: sha, metadata: { "repo" => repo_url })],
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
      sig { params(repo: String, ref: String).returns(String) }
      def resolve_ref(repo, ref)
        return ref if ref.to_s.length == 40 && ref.to_s.match?(/\A[0-9a-f]+\z/)

        out, _err, status = Open3.capture3("git", "ls-remote", "--tags", repo, ref.to_s)
        return T.must(out.lines.first&.split&.first) if status.success? && !out.strip.empty?

        out, _err, status = Open3.capture3("git", "ls-remote", repo, "refs/heads/#{ref}")
        return T.must(out.lines.first&.split&.first) if status.success? && !out.strip.empty?

        raise RefResolutionError, "Could not resolve ref '#{ref}' for #{repo}"
      end
    end
  end
end

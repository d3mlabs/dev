# typed: strict
# frozen_string_literal: true

require "open3"
require_relative "declarations"
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

      # Report a git dependency's universe: the probed ref resolved to its
      # full SHA, as a singleton.
      #
      # The probe is required and is the canonical non-enumerable coordinate:
      # `git ls-remote` lists refs, never reachable SHAs, so a commit can only
      # be asked about, not discovered. The ref the SHA resolved from rides
      # metadata as a fact for GitScheme's tag matching. SHAs are identifiers,
      # not integrity digests, so the version carries no digest.
      #
      # @param id [PackageId] source is the git remote URL
      # @param probe [String, nil] the pinned ref (tag, branch, or SHA); required
      # @return [Package] a singleton universe
      # @raise [RefResolutionError] if no ref is pinned or it cannot be
      #   resolved via ls-remote
      sig { override.params(id: PackageId, probe: T.nilable(String)).returns(Package) }
      def find(id, probe: nil)
        repo_url = T.must(id.source)
        raise RefResolutionError, "git dependency #{id.name} declares no tag: or commit:" if probe.nil?

        sha = resolve_ref(repo_url, probe)

        Package.new(
          id: id,
          versions: [
            PackageVersion.new(
              version: sha,
              metadata: { "repo" => repo_url, "ref" => probe },
              # A checked-out source tree carries no manifest dev reads;
              # consumers declare what they need alongside it.
              declarations: Declarations::Resolved.new([]),
            ),
          ],
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

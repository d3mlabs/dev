# frozen_string_literal: true

require "json"
require "open3"
require_relative "repository"
require_relative "dependency"

module Dev
  module Deps
    # Resolves GitHub release dependencies via the gh CLI.
    #
    # Resolution is a single metadata API call — no artifact download.
    # Per-asset SHA256 digests reported by the GitHub API are recorded in
    # metadata so GhIntegration can verify downloads against the lockfile.
    #
    # Declared in dependencies.rb as:
    #   gh "satisfactorymodding/UnrealEngine",
    #      tag: "5.6.1-css-83",
    #      assets: "UnrealEngine-CSS-Editor-Linux.tar.zst.*",
    #      install_dir: "~/.dev/engines/unreal-engine-css"
    class GhRepository < Repository
      class GhMissingError < StandardError; end
      class AuthenticationError < StandardError; end
      class RepoAccessError < StandardError; end
      class ReleaseNotFoundError < StandardError; end
      class NoMatchingAssetsError < StandardError; end
      class ApiError < StandardError; end

      # Resolve a GitHub release dependency to a pinned Dependency.
      #
      # @param id [Hash] must include "name", "repo" (owner/repo slug), "tag",
      #   "assets" (glob pattern), "install_dir", "integration", "group"
      # @return [Dependency]
      # @raise [GhMissingError] if the gh CLI is not installed
      # @raise [AuthenticationError] if gh is not authenticated
      # @raise [RepoAccessError] if the repo is not visible to the account
      # @raise [ReleaseNotFoundError] if the tag has no release
      # @raise [NoMatchingAssetsError] if no assets match the pattern
      def fetch(id)
        repo_slug = id["repo"]
        tag = id["tag"]
        pattern = id["assets"]

        release = fetch_release(repo_slug, tag)
        assets = matching_assets(release, pattern)
        if assets.empty?
          raise NoMatchingAssetsError,
                "no assets matching #{pattern.inspect} in #{repo_slug}@#{tag}"
        end

        Dependency.new(
          name: id["name"],
          integration: id["integration"].to_sym,
          group: id["group"].to_sym,
          version: tag,
          hash: nil,
          metadata: {
            "repo" => repo_slug,
            "asset_pattern" => pattern,
            "install_dir" => id["install_dir"],
            "assets" => assets.map { |asset| asset_metadata(asset) },
          },
        )
      end

      private

      # Fetch release metadata for a tag, mapping gh failures to actionable errors.
      #
      # @param repo_slug [String] "owner/repo"
      # @param tag [String] release tag
      # @return [Hash] parsed release JSON
      def fetch_release(repo_slug, tag)
        out, err, status = run_gh_api("repos/#{repo_slug}/releases/tags/#{tag}")
        return JSON.parse(out) if status.success?

        raise_auth_error!(err)
        raise_not_found_error!(repo_slug, tag) if not_found?(err)
        raise ApiError, "gh api failed for #{repo_slug}@#{tag}: #{err.strip}"
      end

      # Distinguish "repo invisible" (account not linked) from "tag missing".
      # Forks of private repos 404 for accounts without access, so a second
      # probe of the repo itself tells us which problem the user has.
      #
      # @param repo_slug [String] "owner/repo"
      # @param tag [String] release tag
      def raise_not_found_error!(repo_slug, tag)
        _out, _err, status = run_gh_api("repos/#{repo_slug}")
        if status.success?
          raise ReleaseNotFoundError, "no release tagged #{tag.inspect} in #{repo_slug}"
        end

        raise RepoAccessError, <<~MSG
          #{repo_slug} is not visible to your GitHub account.
          For satisfactorymodding/UnrealEngine: link your GitHub account to Epic Games,
          accept the EpicGames org invitation (github.com/orgs/EpicGames/invitation),
          and run the ficsit.app account linker. See:
          https://docs.ficsit.app/satisfactory-modding/latest/Development/BeginnersGuide/dependencies.html
        MSG
      end

      # @param err [String] gh stderr output
      def raise_auth_error!(err)
        return unless err.include?("gh auth login")

        raise AuthenticationError, "gh is not authenticated — run: gh auth login"
      end

      # @param err [String] gh stderr output
      # @return [Boolean]
      def not_found?(err)
        err.include?("HTTP 404")
      end

      # Run a gh api call. Isolated so tests can stub the CLI boundary.
      #
      # @param path [String] API path (e.g. "repos/owner/repo/releases/tags/v1")
      # @return [Array(String, String, Process::Status)] stdout, stderr, status
      def run_gh_api(path)
        Open3.capture3("gh", "api", path)
      rescue Errno::ENOENT
        raise GhMissingError, "gh CLI not found — install it with: brew install gh"
      end

      # Select release assets whose names match the glob pattern.
      #
      # @param release [Hash] parsed release JSON
      # @param pattern [String] glob pattern (e.g. "*.tar.zst.*")
      # @return [Array<Hash>] matching asset objects
      def matching_assets(release, pattern)
        assets = release["assets"] || []
        assets.select { |asset| File.fnmatch(pattern, asset["name"]) }
      end

      # Map an API asset object to lockfile metadata. The API digest is
      # "sha256:<hex>"; we strip the prefix. Assets without a digest omit the
      # key — GhIntegration only verifies assets that have one.
      #
      # @param asset [Hash] API asset object
      # @return [Hash] { "name", "size", "sha256"? }
      def asset_metadata(asset)
        metadata = { "name" => asset["name"], "size" => asset["size"] }
        digest = asset["digest"]
        metadata["sha256"] = digest.delete_prefix("sha256:") if digest&.start_with?("sha256:")
        metadata
      end
    end
  end
end

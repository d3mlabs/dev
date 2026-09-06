# typed: strict
# frozen_string_literal: true

require "json"
require "open3"
require_relative "declarations"
require_relative "package"
require_relative "package_id"
require_relative "package_version"
require_relative "repository"

module Dev
  module Deps
    # Resolves GitHub release dependencies via the gh CLI.
    #
    # Resolution is metadata API calls only — no artifact download. Per-asset
    # SHA256 digests reported by the GitHub API are recorded in metadata so
    # GhIntegration can verify downloads against the lockfile.
    #
    # Declared in dependencies.rb as:
    #   gh "satisfactorymodding/UnrealEngine",
    #      tag: "5.6.1-css-83",
    #      assets: "UnrealEngine-CSS-Editor-Linux.tar.zst.*",
    #      install_dir: "~/.dev/engines/unreal-engine-css"
    class GhRepository < Repository
      extend T::Sig

      class GhMissingError < StandardError; end
      class AuthenticationError < StandardError; end
      class RepoAccessError < StandardError; end
      class ReleaseNotFoundError < PackageNotFoundError; end
      class MissingTagError < StandardError; end
      class ApiError < StandardError; end

      # Report a GitHub dependency's universe: the probed tag, as a
      # singleton.
      #
      # The probe is required: GitHub refs are enumerable in principle, but
      # each version's facts (commit SHA, release assets and digests) cost
      # API calls per version, so this universe answers for one coordinate
      # at a time. The version's facts are declaration-independent: the
      # commit SHA the ref points at, and every release asset when the tag
      # has a release — asset selection against the declared glob happens at
      # install (GhIntegration), where the glob arrives via the pin's
      # materialization.
      #
      # @param id [PackageId] source is the "owner/repo" slug
      # @param probe [String, nil] the pinned tag; required
      # @return [Package] a singleton universe
      # @raise [MissingTagError] if the declaration pins no tag
      # @raise [GhMissingError] if the gh CLI is not installed
      # @raise [AuthenticationError] if gh is not authenticated
      # @raise [RepoAccessError] if the repo is not visible to the account
      # @raise [ReleaseNotFoundError] if the repo has no such tag
      sig { override.params(id: PackageId, probe: T.nilable(String)).returns(Package) }
      def find(id, probe: nil)
        repo_slug = T.must(id.source)
        raise MissingTagError, "gh dependency #{id.name} declares no tag" if probe.nil?

        metadata = {
          "repo" => repo_slug,
          "commit" => resolve_commit_sha(repo_slug, probe),
        }
        release = fetch_release(repo_slug, probe)
        metadata["assets"] = (release["assets"] || []).map { |asset| asset_metadata(asset) } if release

        version = PackageVersion.new(
          version: probe,
          metadata: metadata,
          # Usage contract, not a guarantee: prebuilt assets baked their needs
          # in at build time, and a source build's transitive needs are
          # declared by the consuming project's own dependencies.rb rows.
          # Revisit when subproject resolution lands.
          declarations: Declarations::Resolved.new([]),
        )
        Package.new(id: id, versions: [version])
      end

      private

      # Resolve a tag to its commit SHA, mapping gh failures to actionable errors.
      #
      # @param repo_slug [String] "owner/repo"
      # @param tag [String] tag/ref
      # @return [String] commit SHA
      sig { params(repo_slug: String, tag: String).returns(String) }
      def resolve_commit_sha(repo_slug, tag)
        out, err, status = run_gh_api("repos/#{repo_slug}/commits/#{tag}")
        return JSON.parse(out)["sha"] if status.success?

        raise_auth_error!(err)
        raise_not_found_error!(repo_slug, tag) if not_found?(err)
        raise ApiError, "gh api failed resolving #{repo_slug}@#{tag}: #{err.strip}"
      end

      # Fetch release metadata for a tag. A 404 is a fact, not a failure: the
      # tag exists (resolve_commit_sha proved it) but publishes no release, so
      # the version simply has no assets.
      #
      # @param repo_slug [String] "owner/repo"
      # @param tag [String] release tag
      # @return [Hash, nil] parsed release JSON, or nil when the tag has no release
      sig { params(repo_slug: String, tag: String).returns(T.nilable(T::Hash[String, T.untyped])) }
      def fetch_release(repo_slug, tag)
        out, err, status = run_gh_api("repos/#{repo_slug}/releases/tags/#{tag}")
        return JSON.parse(out) if status.success?
        return nil if not_found?(err)

        raise_auth_error!(err)
        raise ApiError, "gh api failed for #{repo_slug}@#{tag}: #{err.strip}"
      end

      # Distinguish "repo invisible" (account not linked) from "tag missing".
      # Forks of private repos 404 for accounts without access, so a second
      # probe of the repo itself tells us which problem the user has.
      #
      # @param repo_slug [String] "owner/repo"
      # @param tag [String] release tag
      sig { params(repo_slug: String, tag: String).void }
      def raise_not_found_error!(repo_slug, tag)
        _out, _err, status = run_gh_api("repos/#{repo_slug}")
        if status.success?
          raise ReleaseNotFoundError, "no release or tag #{tag.inspect} in #{repo_slug}"
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
      sig { params(err: String).void }
      def raise_auth_error!(err)
        return unless err.include?("gh auth login")

        raise AuthenticationError, "gh is not authenticated — run: gh auth login"
      end

      # @param err [String] gh stderr output
      # @return [Boolean]
      sig { params(err: String).returns(T::Boolean) }
      def not_found?(err)
        err.include?("HTTP 404")
      end

      # Run a gh api call. Isolated so tests can stub the CLI boundary.
      #
      # @param path [String] API path (e.g. "repos/owner/repo/releases/tags/v1")
      # @return [Array(String, String, Process::Status)] stdout, stderr, status
      sig { params(path: String).returns([String, String, Process::Status]) }
      def run_gh_api(path)
        Open3.capture3("gh", "api", path)
      rescue Errno::ENOENT
        raise GhMissingError, "gh CLI not found — install it with: brew install gh"
      end

      # Map an API asset object to lockfile metadata. The API digest is
      # "sha256:<hex>"; we strip the prefix. Assets without a digest omit the
      # key — GhIntegration only verifies assets that have one.
      #
      # @param asset [Hash] API asset object
      # @return [Hash] { "name", "size", "sha256"? }
      sig { params(asset: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
      def asset_metadata(asset)
        metadata = { "name" => asset["name"], "size" => asset["size"] }
        digest = asset["digest"]
        metadata["sha256"] = digest.delete_prefix("sha256:") if digest&.start_with?("sha256:")
        metadata
      end
    end
  end
end

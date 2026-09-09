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
    # Reports GitHub-hosted dependencies via the gh CLI: the discrete
    # universe is the repo's tags and releases, fully enumerated with facts.
    #
    # Two paginated list calls cover everything: the releases list carries
    # each release's assets (names, sizes, API-reported SHA256 digests) and
    # the tags list carries each tag's commit SHA — so enumeration is
    # facts-complete with no per-version calls. Resolution is metadata only,
    # no artifact download; digests are recorded so GhIntegration can verify
    # downloads against the lockfile. Asset selection against the declared
    # glob happens at install, where the glob arrives via the pin's
    # materialization.
    #
    # Declared in dependencies.rb as:
    #   gh "UnrealEngine",
    #      github: "d3mlabs/unreal-engine",
    #      tag: "5.8.0-wine-7",
    #      assets: "UnrealEngine-Wine-Editor-Linux.tar.zst.*",
    #      install_dir: "~/.dev/engines/ue5"
    class GhRepository < Repository
      extend T::Sig

      class GhMissingError < StandardError; end
      class AuthenticationError < StandardError; end
      class RepoAccessError < StandardError; end
      class ApiError < StandardError; end

      # GitHub's maximum page size; fewer results than this ends pagination.
      PER_PAGE = 100

      # Report a GitHub dependency's universe: every tag and release.
      #
      # Universe order feeds the unconstrained pick (ExactScheme preserves
      # order and the Resolver takes the last sorted version): tag-only
      # versions first, then releases oldest to newest, so an unconstrained
      # gh dep pins the latest release rather than an arbitrary tag.
      #
      # @param id [PackageId] source is the "owner/repo" slug
      # @return [Package] one version per tag/release, facts complete
      # @raise [GhMissingError] if the gh CLI is not installed
      # @raise [AuthenticationError] if gh is not authenticated
      # @raise [RepoAccessError] if the repo is not visible to the account
      # @raise [PackageNotFoundError] if the repo has no tags or releases
      sig { override.params(id: PackageId).returns(Package) }
      def find(id)
        repo_slug = T.must(id.source)
        releases = list(repo_slug, "releases")
        tags = list(repo_slug, "tags")
        if releases.empty? && tags.empty?
          raise PackageNotFoundError, "#{repo_slug} publishes no tags or releases"
        end

        commit_by_tag = tags.to_h { |tag| [tag["name"], tag.dig("commit", "sha")] }
        # Drafts have no tag yet; they are not part of the published universe.
        release_by_tag = releases.reject { |release| release["draft"] }
          .to_h { |release| [release["tag_name"], release] }

        tag_only = commit_by_tag.keys - release_by_tag.keys
        ordered = tag_only + release_by_tag.keys.reverse

        versions = ordered.map do |tag|
          version_for(repo_slug, tag, commit_by_tag[tag], release_by_tag[tag])
        end
        Package.new(id: id, versions: versions)
      end

      private

      # Assemble one tag's facts: the commit SHA it points at and, when it
      # publishes a release, every asset — unselected.
      #
      # @param repo_slug [String] "owner/repo"
      # @param tag [String] tag name (the version string)
      # @param commit [String, nil] commit SHA from the tags list
      # @param release [Hash, nil] release object from the releases list
      # @return [PackageVersion]
      sig do
        params(
          repo_slug: String,
          tag: String,
          commit: T.nilable(String),
          release: T.nilable(T::Hash[String, T.untyped]),
        ).returns(PackageVersion)
      end
      def version_for(repo_slug, tag, commit, release)
        metadata = T.let({ "repo" => repo_slug }, T::Hash[String, T.untyped])
        metadata["commit"] = commit if commit
        metadata["assets"] = (release["assets"] || []).map { |asset| asset_metadata(asset) } if release

        PackageVersion.new(
          version: tag,
          metadata: metadata,
          # Usage contract, not a guarantee: prebuilt assets baked their needs
          # in at build time, and a source build's transitive needs are
          # declared by the consuming project's own dependencies.rb rows.
          # Revisit when subproject resolution lands.
          declarations: Declarations::Resolved.new([]),
        )
      end

      # Enumerate a paginated list endpoint to exhaustion.
      #
      # @param repo_slug [String] "owner/repo"
      # @param collection [String] "releases" or "tags"
      # @return [Array<Hash>] every object the endpoint lists
      sig { params(repo_slug: String, collection: String).returns(T::Array[T::Hash[String, T.untyped]]) }
      def list(repo_slug, collection)
        results = T.let([], T::Array[T::Hash[String, T.untyped]])
        page = 1
        loop do
          out, err, status = run_gh_api("repos/#{repo_slug}/#{collection}?per_page=#{PER_PAGE}&page=#{page}")
          unless status.success?
            raise_auth_error!(err)
            raise_repo_access_error!(repo_slug) if not_found?(err)
            raise ApiError, "gh api failed listing #{collection} for #{repo_slug}: #{err.strip}"
          end

          batch = JSON.parse(out)
          results.concat(batch)
          break if batch.size < PER_PAGE

          page += 1
        end
        results
      end

      # A 404 on a list endpoint means the repo itself is invisible to the
      # account (list endpoints answer [] for empty collections), which for
      # Epic-gated repos has a known fix worth spelling out.
      #
      # @param repo_slug [String] "owner/repo"
      sig { params(repo_slug: String).void }
      def raise_repo_access_error!(repo_slug)
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
      # @param path [String] API path (e.g. "repos/owner/repo/releases?per_page=100&page=1")
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

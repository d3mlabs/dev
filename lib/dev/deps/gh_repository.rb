# typed: strict
# frozen_string_literal: true

require "json"
require "open3"
require "dev/lifecycle/release_tag"
require "dev/lifecycle/series"
require_relative "declarations"
require_relative "package"
require_relative "package_id"
require_relative "package_version"
require_relative "repository"
require_relative "series_head"

module Dev
  module Deps
    # Reports GitHub-hosted dependencies via the gh CLI: the discrete
    # universe is the repo's tags and releases, fully enumerated with facts;
    # the continuous space is the repo's commit SHAs.
    #
    # Two paginated list calls cover everything: the releases list carries
    # each release's assets (names, sizes, API-reported SHA256 digests) and
    # the tags list carries each tag's commit SHA — each version's source,
    # since a tag can be moved and its commit cannot — so enumeration is
    # facts-complete with no per-version calls (an empty releases list costs
    # one more: a /releases/latest cross-check, see #confirmed_releases).
    # Resolution is metadata only,
    # no artifact download; digests are recorded so GhIntegration can verify
    # downloads against the lockfile. Asset selection against the declared
    # glob happens at install, where the glob arrives via the pin's
    # materialization.
    #
    # The tags list also carries the repo's **series tags** — `v1`, `v2`,
    # the per-series heads `dev deploy gh` moves (Lifecycle::GithubHeads)
    # — each at the commit of the release its followers install. A series
    # tag is reported twice over: as a version, like any tag (an exact
    # `tag: "v1"` names it), and as the package's head for its series,
    # naming the version tag cut at the same commit. The head and the
    # versions come from one listing, so the fact a lock resolves through
    # is the one a follower's `@v1` resolves to.
    #
    # Commit SHAs are unreachable by enumeration (no endpoint lists reachable
    # commits), so a commit pin arrives as the declaration's revision and is
    # lifted by at — pure, no network, exactly as GitRepository#at: a full
    # SHA is self-certifying as an address, and existence surfaces at fetch
    # time. A commit publishes no release, so its only materialization is a
    # source build (GhIntegration fetches the commit's tarball).
    #
    # Declared in dependencies.rb as:
    #   gh "UnrealEngine",
    #      github: "d3mlabs/unreal-engine",
    #      tag: "5.8.0-wine-7",
    #      assets: "UnrealEngine-Wine-Editor-Linux.tar.zst.*"
    # or, at a commit:
    #   gh "json", github: "nlohmann/json",
    #      sha: "9cca280a4d0ccf0c08f47a99aa71d1b0e52f8d03", build: :none
    class GhRepository < Repository
      extend T::Sig

      class GhMissingError < StandardError; end
      class AuthenticationError < StandardError; end
      class RepoAccessError < StandardError; end
      class ApiError < StandardError; end
      class InconsistentReleasesError < StandardError; end

      # GitHub's maximum page size; fewer results than this ends pagination.
      PER_PAGE = 100

      # How many times an empty releases list that /releases/latest contradicts
      # is re-fetched before find refuses. The releases list endpoint has been
      # observed answering `200 []` for repos with releases (same ETag as the
      # full body) on a sizeable fraction of calls; /releases/latest and the
      # tags list have not. Trusting the empty list would mint pins without
      # their release facts — no assets, nothing to verify a download against.
      RELEASES_RETRIES = 4

      # Seconds between re-fetches, per attempt.
      RELEASES_RETRY_BACKOFF = [1, 2, 4, 8].freeze

      # Report a GitHub dependency's universe: every tag and release, and
      # the head of every series the repo keeps a series tag for.
      #
      # Tag-only versions first, then releases oldest to newest; the
      # Resolver takes the greatest satisfying tag under TagScheme's
      # ordering — or the series head, for a requirement that names whole
      # series on a repo that deploys heads.
      #
      # @param id [PackageId] source is the "owner/repo" slug
      # @return [Package] one version per tag/release, facts complete; one head per series tag
      # @raise [GhMissingError] if the gh CLI is not installed
      # @raise [AuthenticationError] if gh is not authenticated
      # @raise [RepoAccessError] if the repo is not visible to the account
      # @raise [PackageNotFoundError] if the repo has no tags or releases
      # @raise [InconsistentReleasesError] if the releases list keeps answering
      #   empty while /releases/latest reports a release
      sig { override.params(id: PackageId).returns(Package) }
      def find(id)
        repo_slug = T.must(id.source)
        releases = list(repo_slug, "releases")
        tags = list(repo_slug, "tags")
        if releases.empty? && tags.empty?
          raise PackageNotFoundError, "#{repo_slug} publishes no tags or releases"
        end

        releases = confirmed_releases(repo_slug) if releases.empty?

        commit_by_tag = T.let(tags.to_h { |tag| [tag["name"].to_s, tag.dig("commit", "sha")] }, T::Hash[String, T.nilable(String)])
        # Drafts have no tag yet; they are not part of the published universe.
        release_by_tag = releases.reject { |release| release["draft"] }
          .to_h { |release| [release["tag_name"], release] }

        tag_only = commit_by_tag.keys - release_by_tag.keys
        ordered = tag_only + release_by_tag.keys.reverse

        versions = ordered.map do |tag|
          version_for(repo_slug, tag, commit_by_tag[tag], release_by_tag[tag])
        end
        # A series tag stays a version too — `tag: "v1"` is an exact ask it
        # answers — and is besides the pointer its series' head is read from.
        heads = commit_by_tag.filter_map do |name, sha|
          head_for(Lifecycle::Series.of_tag(name), sha, commit_by_tag) if Lifecycle::Series.tag?(name)
        end
        Package.new(id: id, versions: versions, heads: heads)
      end

      # Lift a commit SHA into a version. Pure — no network: the SHA is the
      # version and the integrity statement, the author already chose it,
      # and a bad address surfaces at fetch time (GitHub's tarball endpoint
      # answers 404 for a commit the repo does not have). No release facts
      # ride along: a commit publishes none.
      #
      # @param id [PackageId] source is the "owner/repo" slug
      # @param revision [String] full 40-char commit SHA (DSL-validated)
      # @return [PackageVersion]
      sig { override.params(id: PackageId, revision: String).returns(PackageVersion) }
      def at(id, revision)
        PackageVersion.new(
          version: revision,
          source: revision,
          metadata: { "repo" => T.must(id.source) },
          declarations: Declarations::Resolved.new([]),
        )
      end

      private

      # The head a series tag names: the version tag of that series cut at
      # the commit the series tag points at (`v1` at the commit of
      # `v1.3.0` → `v1 → v1.3.0`), the greatest when several are. A series
      # tag at a commit no version of its series was cut at — a pointer
      # moved by hand, a series tag of another naming — names no version
      # of the universe and is no head.
      #
      # @param series [Lifecycle::Series] the series the tag is kept for
      # @param sha [String, nil] the commit the series tag points at
      # @param commit_by_tag [Hash{String => String, nil}] every version tag's commit
      # @return [SeriesHead, nil]
      sig do
        params(
          series: Lifecycle::Series,
          sha: T.nilable(String),
          commit_by_tag: T::Hash[String, T.nilable(String)],
        ).returns(T.nilable(SeriesHead))
      end
      def head_for(series, sha, commit_by_tag)
        return nil if sha.nil?

        at_commit = commit_by_tag.select { |tag, commit| commit == sha && release_of?(series, tag) }.keys
        version = at_commit.max_by { |tag| Gem::Version.new(tag.delete_prefix(Lifecycle::ReleaseTag::PREFIX)) }
        SeriesHead.new(series: series, version: version) unless version.nil?
      end

      # Whether a tag is a release of a series: `v` and a version of that
      # major, as Lifecycle::GithubHeads reads a release tag — and not a
      # series tag, whose bare major reads as a version too.
      #
      # @param series [Lifecycle::Series]
      # @param tag [String] a tag name
      # @return [Boolean]
      sig { params(series: Lifecycle::Series, tag: String).returns(T::Boolean) }
      def release_of?(series, tag)
        return false if Lifecycle::Series.tag?(tag)

        word = tag.delete_prefix(Lifecycle::ReleaseTag::PREFIX)
        Lifecycle::Series.version?(word) && series.includes?(word)
      end

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
          # A tag moves; the commit it points at is what the tag's tree
          # and release are of. A release whose tag the tags list did not
          # carry has no commit, and so no source.
          source: commit,
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

      # Settle an empty releases list: tag-only repo, or a lying replica?
      #
      # /releases/latest answers 404 for a repo with no (non-prerelease)
      # releases and 200 otherwise, and has not been seen to flake. A 404
      # confirms the empty list. A 200 contradicts it: the list is re-fetched
      # with backoff until it agrees, and if it never does, find refuses —
      # a universe missing its release facts must not become a pin.
      #
      # Known gap: a repo whose only releases are prereleases also gets a
      # 404 from /releases/latest, so a flake there goes undetected.
      #
      # @param repo_slug [String] "owner/repo"
      # @return [Array<Hash>] the confirmed (possibly empty) releases list
      # @raise [InconsistentReleasesError] if the list stays empty against
      #   /releases/latest after RELEASES_RETRIES re-fetches
      sig { params(repo_slug: String).returns(T::Array[T::Hash[String, T.untyped]]) }
      def confirmed_releases(repo_slug)
        latest = latest_release(repo_slug)
        return [] unless latest

        RELEASES_RETRIES.times do |attempt|
          pause(T.must(RELEASES_RETRY_BACKOFF[attempt]))
          releases = list(repo_slug, "releases")
          return releases unless releases.empty?
        end

        raise InconsistentReleasesError, <<~MSG.strip
          GitHub listed no releases for #{repo_slug} on #{1 + RELEASES_RETRIES} attempts, \
          yet reports #{latest["tag_name"].inspect} as its latest release. \
          Refusing to resolve from a universe missing its release facts; retry later.
        MSG
      end

      # The repo's latest non-prerelease release, or nil when it has none.
      #
      # @param repo_slug [String] "owner/repo"
      # @return [Hash, nil] the release object
      # @raise [AuthenticationError] if gh is not authenticated
      # @raise [ApiError] on any failure other than 404
      sig { params(repo_slug: String).returns(T.nilable(T::Hash[String, T.untyped])) }
      def latest_release(repo_slug)
        out, err, status = run_gh_api("repos/#{repo_slug}/releases/latest")
        return JSON.parse(out) if status.success?

        raise_auth_error!(err)
        return nil if not_found?(err)

        raise ApiError, "gh api failed fetching the latest release for #{repo_slug}: #{err.strip}"
      end

      # Wait between re-fetches. Isolated so tests can stub the clock.
      #
      # @param seconds [Integer]
      sig { params(seconds: Integer).void }
      def pause(seconds)
        Kernel.sleep(seconds)
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

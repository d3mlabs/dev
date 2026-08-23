# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "pathname"
require_relative "../deps"
require_relative "../settings"
require_relative "cache"
require_relative "dependency"
require_relative "registry"

module Dev
  module Deps
    # The host baseline layer (plans#26): the org-invariant tools every host
    # needs (e.g. git, gh, rbenv, shadowenv, the agent CLI), declared in a
    # manifest that lives in the org's repo named by the `baseline_repo`
    # setting — dev is public and ships no org content, so the org names its
    # manifest source and dev supplies the machinery. Unset means no
    # baseline: the whole layer is off.
    #
    # Deliberately lockless: every baseline entry is a Homebrew name, and
    # brew installs by name — the baseline is *convergence toward a tool
    # set*, not version pinning, so a resolved lockfile would record versions
    # nothing enforces.
    #
    # The manifest is cached machine-locally (next to the stamp, under XDG
    # data): `dev up` refreshes the cache from the org repo and converges
    # when the cached digest drifts from the per-host stamp; a failed fetch
    # falls back to the cached copy, so offline `dev up` still works. Every
    # other command surfaces staleness as a warn-only O(1) nag (cached
    # digest vs stamp, never network) via DependencyService#guard! — the
    # baseline never blocks, even in CI.
    class Baseline
      STALE_MESSAGE = "host baseline stale — run `dev up`"

      STAMP_FILE = "converged-digest"

      CACHE_FILE = "dependencies.rb"

      # Conventional manifest location inside the org's baseline repo.
      MANIFEST_REPO_PATH = "baseline/dependencies.rb"

      # Fetches a file's raw content from a repo's default branch through
      # the gh CLI — the same boundary shape as Plan::GithubIssues#repo_file.
      # nil for any failure: the caller decides the fallback.
      class GhFetcher
        # @param owner_repo [String] "owner/repo"
        # @param path [String] file path inside the repo
        # @return [String, nil] the file content, or nil when unavailable
        def repo_file(owner_repo, path)
          out, _err, status = Open3.capture3(
            "gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/#{owner_repo}/contents/#{path}"
          )
          status.success? ? out : nil
        rescue SystemCallError
          nil
        end
      end

      # @param settings [Dev::Settings] source of the baseline_repo key
      # @param state_dir [Pathname, String] host state root — XDG data home
      #   like the learnings cache, NOT ~/.dev/state: project stamps are
      #   per-checkout working state; this is host-layer state
      # @param fetcher [#repo_file] raw-content boundary, injectable so
      #   tests never touch the network
      # @param integrations_factory [#call] () → {Symbol => Integration};
      #   the install seam, injectable so tests never touch the host
      def initialize(settings: Dev::Settings.new, state_dir: default_state_dir,
        fetcher: GhFetcher.new, integrations_factory: nil)
        @settings = settings
        @state_dir = Pathname(state_dir)
        @fetcher = fetcher
        @integrations_factory = integrations_factory ||
          -> { Registry.host_integrations(project_root: cache_path.dirname, cache: Cache.new) }
      end

      # The warn-only nag for a stale host, nil when converged. Computed
      # from the machine-local cache only — O(1), never network. A machine
      # without a configured baseline repo has nothing to converge and is
      # never stale.
      #
      # @return [String, nil]
      def message
        stale? ? STALE_MESSAGE : nil
      end

      # The converge `dev up` runs first: refresh the cached manifest from
      # the org repo (falling back to the cached copy when the fetch fails,
      # so offline runs still work), then install and stamp when the cache
      # digest drifted from the per-host stamp. One digest comparison on a
      # warm host after the refresh.
      #
      # @return [Boolean] whether a converge ran
      def converge_if_stale
        return false unless baseline_repo

        refresh_cache
        return false unless stale? && cache_path.file?

        converge
        true
      end

      private

      # @return [String, nil] the org repo named in settings, or nil (layer off)
      def baseline_repo
        @settings.baseline_repo
      end

      # Fetch the manifest fresh and rewrite the cache; a failed fetch keeps
      # the cached copy (with a warning), so a fresh box with no cache stays
      # stale and keeps nagging.
      #
      # @return [void]
      def refresh_cache
        content = @fetcher.repo_file(baseline_repo, MANIFEST_REPO_PATH)
        if content
          FileUtils.mkdir_p(cache_path.dirname)
          cache_path.write(content)
        else
          detail = cache_path.file? ? " — converging from the cached copy" : ""
          $stderr.puts "dev: warning: could not fetch baseline manifest from #{baseline_repo}#{detail}"
        end
      end

      # Install the cached manifest's declarations (filtered to this host
      # OS) and stamp the host converged. Stamping only happens after a
      # fully-successful install, so a crashed run keeps nagging.
      #
      # @return [void]
      def converge
        integrations = @integrations_factory.call
        host_dependencies.group_by(&:integration).each do |type, dependencies|
          integrations.fetch(type).install_all(dependencies)
        end
        stamp!
      end

      # A host is stale when a baseline repo is configured and this host's
      # stamp doesn't match the cached manifest — including the fresh-box
      # case where neither cache nor stamp exists yet.
      #
      # @return [Boolean]
      def stale?
        return false unless baseline_repo

        cache_digest != stamped_digest || stamped_digest.nil?
      end

      # The manifest's declarations as installable Dependencies, minus other
      # hosts' entries (e.g. the darwin-gated agent CLI on a Linux target
      # host). No resolve step: the constraint hash IS the install metadata
      # — brew converges by name, so there is no resolved version to carry.
      #
      # @return [Array<Dependency>]
      def host_dependencies
        host = Deps.detect_host
        declarations.filter_map do |declaration|
          next if declaration.host && declaration.host.to_s != host

          Dependency.new(
            name: declaration.name,
            integration: declaration.integration,
            group: declaration.group,
            version: nil,
            hash: nil,
            metadata: declaration.constraint,
          )
        end
      end

      # @return [Array<DependencyDeclaration>] the cached manifest's declarations
      def declarations
        Deps.reset!
        Kernel.load(cache_path.to_s)
        Deps.last_config&.declarations || []
      end

      # @return [String, nil] SHA-256 hex of the cached manifest, nil without one
      def cache_digest
        cache_path.file? ? Digest::SHA256.file(cache_path.to_s).hexdigest : nil
      end

      # @return [String, nil] the last converged manifest digest on this host
      def stamped_digest
        stamp_path.file? ? stamp_path.read.strip : nil
      end

      # Record the just-converged manifest digest.
      #
      # @return [void]
      def stamp!
        FileUtils.mkdir_p(stamp_path.dirname)
        stamp_path.write(cache_digest)
      end

      # The machine-local copy of the org manifest, next to the stamp. The
      # cache is what the nag and the converge read; the org repo is only
      # touched by refresh_cache.
      #
      # @return [Pathname]
      def cache_path
        @state_dir / "host-baseline" / CACHE_FILE
      end

      # Fixed host-singular stamp path: the baseline is per-host state.
      #
      # @return [Pathname]
      def stamp_path
        @state_dir / "host-baseline" / STAMP_FILE
      end

      # @return [String] $XDG_DATA_HOME/dev (the learnings-cache precedent)
      def default_state_dir
        data_home = ENV.fetch("XDG_DATA_HOME", File.join(Dir.home, ".local", "share"))
        File.join(data_home, "dev")
      end
    end
  end
end

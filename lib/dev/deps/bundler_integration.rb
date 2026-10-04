# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "integration"
require_relative "dependency"
require_relative "shadowenv_exec"

module Dev
  module Deps
    # Lifecycle handler for Ruby gem dependencies.
    #
    # Installs the locked gems with `bundle install` against the Gemfile/
    # Gemfile.lock that BundlerRepository generated and committed. The install is
    # frozen: it must match the committed lockfile exactly, so install never
    # silently re-resolves (re-resolution is `dev deps update`'s job).
    #
    # The individual locked deps are informational here — bundler installs the
    # full graph from the Gemfile.lock — so install_all only needs to know there
    # is at least one gem to install.
    #
    # Bundler owns the fetch, the integrity check (Gemfile.lock CHECKSUMS) and
    # the install; dev only names where bundler caches what it fetches — the
    # store's bundler tool cache, under the data root, so the host's bundle and
    # the container's share one download cache (pure-Ruby gems fetch once;
    # platform gems have distinct filenames and never collide).
    class BundlerIntegration < Integration
      extend T::Sig

      class InstallError < StandardError; end
      class BundlerMissingError < StandardError; end

      GEMFILE = "Gemfile"
      TOOL = "bundler"

      # @param repository     [Repository, nil]  source adapter for bundler deps
      # @param store          [ArtifactStore, nil] the store whose bundler tool cache bundler downloads into
      # @param project_root   [String, Pathname] root the generated Gemfile lives in
      # @param shadowenv_exec [ShadowenvExec]    spawn seam for the project's Ruby toolchain
      sig do
        params(
          repository: T.nilable(Repository),
          store: T.nilable(ArtifactStore),
          project_root: T.any(String, Pathname),
          shadowenv_exec: ShadowenvExec,
        ).void
      end
      def initialize(repository:, store:, project_root:, shadowenv_exec: ShadowenvExec.new(project_root: project_root))
        super(repository:, store:)
        @project_root = T.let(Pathname(project_root), Pathname)
        @shadowenv_exec = shadowenv_exec
      end

      # Install all gems via `bundle install` against the generated Gemfile.
      #
      # @param dependencies [Array<Dependency>] bundler deps (presence-only)
      # @return [void]
      sig { params(dependencies: T::Array[Dependency]).void }
      def install_all(dependencies)
        return if dependencies.empty?

        ensure_bundler!
        run_bundle_install
      end

      private

      # Every subprocess below goes through the ShadowenvExec seam: the
      # project's provisioned Ruby (not whatever the host's PATH carries),
      # with dev's own gem env kept out of the child so the installed gems
      # land in the project's gem home, never dev's (dev#180).

      # Ensure a bundler executable is available in the provisioned Ruby.
      # Bundler ships with modern Ruby, so this is normally a no-op; install
      # it on demand if missing.
      #
      # @raise [BundlerMissingError] if bundler cannot be made available
      # @return [void]
      sig { void }
      def ensure_bundler!
        _out, _err, status = @shadowenv_exec.capture3("bundle", "--version")
        return if status.success?

        _out, err, status = @shadowenv_exec.capture3("gem", "install", "bundler", "--no-document")
        raise BundlerMissingError, "failed to install bundler: #{err}" unless status.success?
      end

      # Run a frozen `bundle install` so the committed Gemfile.lock is
      # authoritative, with bundler's global gem cache in the store.
      #
      # @raise [InstallError] if bundle install fails
      # @return [void]
      sig { void }
      def run_bundle_install
        _out, err, status = @shadowenv_exec.capture3(
          "bundle", "install",
          env: {
            "BUNDLE_GEMFILE" => gemfile_path.to_s,
            "BUNDLE_FROZEN" => "true",
            "BUNDLE_GLOBAL_GEM_CACHE" => "true",
            "BUNDLE_USER_CACHE" => store!.tool_cache(TOOL).to_s,
          },
        )
        raise InstallError, "bundle install failed: #{err}" unless status.success?
      end

      # @return [Pathname]
      sig { returns(Pathname) }
      def gemfile_path
        @project_root / GEMFILE
      end
    end
  end
end

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
    # silently re-resolves (re-resolution is `dev update-deps`'s job).
    #
    # The individual locked deps are informational here — bundler installs the
    # full graph from the Gemfile.lock — so install_all only needs to know there
    # is at least one gem to install.
    class BundlerIntegration < Integration
      extend T::Sig

      class InstallError < StandardError; end
      class BundlerMissingError < StandardError; end

      GEMFILE = "Gemfile"

      # @param repository     [Repository, nil]  source adapter for bundler deps
      # @param cache          [Cache, nil]       shared download cache (unused; bundler caches)
      # @param project_root   [String, Pathname] root the generated Gemfile lives in
      # @param shadowenv_exec [ShadowenvExec]    spawn seam for the project's Ruby toolchain
      sig do
        params(
          repository: T.nilable(Repository),
          cache: T.nilable(Cache),
          project_root: T.any(String, Pathname),
          shadowenv_exec: ShadowenvExec,
        ).void
      end
      def initialize(repository:, cache:, project_root:, shadowenv_exec: ShadowenvExec.new(project_root: project_root))
        super(repository:, cache:)
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

      # Run a frozen `bundle install` so the committed Gemfile.lock is authoritative.
      #
      # @raise [InstallError] if bundle install fails
      # @return [void]
      sig { void }
      def run_bundle_install
        _out, err, status = @shadowenv_exec.capture3(
          "bundle", "install",
          env: { "BUNDLE_GEMFILE" => gemfile_path.to_s, "BUNDLE_FROZEN" => "true" },
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

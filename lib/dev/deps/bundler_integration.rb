# frozen_string_literal: true

require "open3"
require "pathname"
require_relative "integration"
require_relative "dependency"

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
      class InstallError < StandardError; end
      class BundlerMissingError < StandardError; end

      GEMFILE = "Gemfile"

      # @param repository   [Repository] source adapter for bundler deps
      # @param cache        [Cache]      shared download cache (unused; bundler caches)
      # @param project_root [Pathname]   root the generated Gemfile lives in
      def initialize(repository:, cache:, project_root:)
        super(repository:, cache:)
        @project_root = Pathname(project_root)
      end

      # Install all gems via `bundle install` against the generated Gemfile.
      #
      # @param dependencies [Array<Dependency>] bundler deps (presence-only)
      # @return [void]
      def install_all(dependencies)
        return if dependencies.empty?

        ensure_bundler!
        run_bundle_install
      end

      private

      # Ensure a bundler executable is available. Bundler ships with modern Ruby,
      # so this is normally a no-op; install it on demand if missing.
      #
      # @raise [BundlerMissingError] if bundler cannot be made available
      # @return [void]
      def ensure_bundler!
        _out, _err, status = Open3.capture3("bundle", "--version")
        return if status.success?

        _out, err, status = Open3.capture3("gem", "install", "bundler", "--no-document")
        raise BundlerMissingError, "failed to install bundler: #{err}" unless status.success?
      end

      # Run a frozen `bundle install` so the committed Gemfile.lock is authoritative.
      #
      # @raise [InstallError] if bundle install fails
      # @return [void]
      def run_bundle_install
        _out, err, status = Open3.capture3(
          { "BUNDLE_GEMFILE" => gemfile_path.to_s, "BUNDLE_FROZEN" => "true" },
          "bundle", "install",
          chdir: @project_root.to_s,
        )
        raise InstallError, "bundle install failed: #{err}" unless status.success?
      end

      # @return [Pathname]
      def gemfile_path
        @project_root / GEMFILE
      end
    end
  end
end

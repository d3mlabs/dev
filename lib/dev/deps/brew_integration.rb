# frozen_string_literal: true

require "open3"
require "pathname"
require_relative "integration"
require_relative "dependency"
require_relative "tap"

module Dev
  module Deps
    # Lifecycle handler for Homebrew dependencies.
    #
    # install_all installs each formula/cask via brew. Registers taps
    # (if configured) before the first install.
    #
    # Env filtering (install vs skip based on ci/dev) is the caller's
    # responsibility — only pass deps that should be installed.
    class BrewIntegration < Integration
      class InstallError < StandardError; end
      class TapRegistrationError < StandardError; end

      # @param repository [Repository] source adapter
      # @param cache [Cache] shared download cache
      # @param taps [Array<Tap>] Homebrew taps to register before installing
      # @param project_dir [Pathname, nil] project root for resolving file:// tap URLs
      def initialize(repository:, cache:, taps: [], project_dir: nil)
        super(repository:, cache:)
        @taps = taps
        @project_dir = project_dir ? Pathname(project_dir) : nil
        @taps_registered = false
      end

      # Install all brew dependencies. Registers taps on first call.
      #
      # @param dependencies [Array<Dependency>] brew deps to install
      def install_all(dependencies)
        ensure_taps_registered
        dependencies.each do |dep|
          if dep.metadata["cask"]
            install_cask(dep)
          else
            install_formula(dep)
          end
        end
      end

      private

      # Register all configured taps (idempotent — runs once).
      def ensure_taps_registered
        return if @taps_registered

        @taps.each { |tap| register_tap(tap) }
        setup_tap_env
        @taps_registered = true
      end

      # Register a single Homebrew tap.
      #
      # @param tap [Tap] tap to register
      # @raise [TapRegistrationError] if `brew tap` fails
      def register_tap(tap)
        if tap.local? && @project_dir
          path = resolve_file_url(tap.url)
          success = system("brew", "tap", tap.name, path)
          raise TapRegistrationError, "brew tap #{tap.name} #{path} failed" unless success
        elsif tap.url
          url_str = tap.url.to_s
          success = system("brew", "tap", tap.name, url_str)
          raise TapRegistrationError, "brew tap #{tap.name} #{url_str} failed" unless success
        else
          success = system("brew", "tap", tap.name)
          raise TapRegistrationError, "brew tap #{tap.name} failed" unless success
        end
      end

      # Set TAP_NAME and LOCAL_TAP_DIR env vars for the first local tap.
      def setup_tap_env
        return unless @project_dir

        local_tap = @taps.find(&:local?)
        return unless local_tap

        ENV["TAP_NAME"] = local_tap.name
        ENV["LOCAL_TAP_DIR"] = resolve_file_url(local_tap.url) if local_tap.url
      end

      # Resolve a file:// URI to an absolute path relative to project_dir.
      #
      # @param uri [URI] file:// URI
      # @return [String] absolute path
      def resolve_file_url(uri)
        path = uri.path.to_s
        path = (@project_dir / path[2..]).to_s if path.start_with?("./")
        File.expand_path(path)
      end

      # Install a Homebrew formula, constructing the spec from tap/version.
      #
      # @param dep [Dependency]
      # @raise [InstallError] if brew install fails
      def install_formula(dep)
        name = dep.name
        return if brew_installed?(name)

        spec = if dep.metadata["tap"]
          version_suffix = dep.version ? "@#{dep.version}" : ""
          "#{dep.metadata["tap"]}/#{name}#{version_suffix}"
        elsif dep.version
          "#{name}@#{dep.version}"
        else
          name
        end

        run_brew_install(name, spec)
      end

      # Install a Homebrew cask.
      #
      # @param dep [Dependency]
      # @raise [InstallError] if brew install --cask fails
      def install_cask(dep)
        return if brew_installed?(dep.name)
        run_brew_install(dep.name, "--cask #{dep.name}")
      end

      # Check if a formula/cask is already installed.
      #
      # @param name [String] formula or cask name
      # @return [Boolean]
      def brew_installed?(name)
        system("brew list #{name} >/dev/null 2>&1")
      end

      # Run `brew install` with the given spec.
      #
      # @param name [String] dependency name (for error messages)
      # @param spec [String] full install spec (e.g. "cmake@3.31.4")
      # @raise [InstallError] if brew exits non-zero
      def run_brew_install(name, spec)
        _out, err, status = Open3.capture3("brew", "install", *spec.split)
        raise InstallError, "brew install #{spec} failed: #{err}" unless status.success?
      end
    end
  end
end

# typed: strict
# frozen_string_literal: true

require "open3"
require "pathname"
require "uri"
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
      extend T::Sig

      class InstallError < StandardError; end
      class TapRegistrationError < StandardError; end

      # @param repository [Repository, nil] source adapter
      # @param cache [Cache, nil] shared download cache
      # @param taps [Array<Tap>] Homebrew taps to register before installing
      # @param project_dir [String, Pathname, nil] project root for resolving file:// tap URLs
      sig do
        params(
          repository: T.nilable(Repository),
          cache: T.nilable(Cache),
          taps: T::Array[Tap],
          project_dir: T.nilable(T.any(String, Pathname)),
        ).void
      end
      def initialize(repository:, cache:, taps: [], project_dir: nil)
        super(repository:, cache:)
        @taps = taps
        @project_dir = T.let(project_dir ? Pathname(project_dir) : nil, T.nilable(Pathname))
        @taps_registered = T.let(false, T::Boolean)
      end

      # Install all brew dependencies. Registers taps on first call.
      #
      # @param dependencies [Array<Dependency>] brew deps to install
      sig { params(dependencies: T::Array[Dependency]).void }
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
      sig { void }
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
      sig { params(tap: Tap).void }
      def register_tap(tap)
        project_dir = @project_dir
        if tap.local? && project_dir
          path = resolve_file_url(tap.url, project_dir)
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
      sig { void }
      def setup_tap_env
        project_dir = @project_dir
        return unless project_dir

        local_tap = @taps.find(&:local?)
        return unless local_tap

        ENV["TAP_NAME"] = local_tap.name
        ENV["LOCAL_TAP_DIR"] = resolve_file_url(local_tap.url, project_dir) if local_tap.url
      end

      # Resolve a file:// URI to an absolute path relative to project_dir.
      #
      # @param uri [URI::Generic] file:// URI
      # @param project_dir [Pathname] project root ./ paths resolve against
      # @return [String] absolute path
      sig { params(uri: URI::Generic, project_dir: Pathname).returns(String) }
      def resolve_file_url(uri, project_dir)
        path = uri.path.to_s
        # T.must: start_with?("./") guarantees at least two leading chars.
        path = (project_dir / T.must(path[2..])).to_s if path.start_with?("./")
        File.expand_path(path)
      end

      # Install a Homebrew formula.
      #
      # The install target is the versioned formula (e.g. "llvm@18"), built from
      # the declared version *suffix* in metadata — never the resolved stable
      # version (dep.version), which is a record like "18.1.8" and is not a valid
      # formula name (there is no "llvm@18.1.8").
      #
      # @param dep [Dependency]
      # @raise [InstallError] if brew install fails
      sig { params(dep: Dependency).void }
      def install_formula(dep)
        suffix = dep.metadata["version_suffix"]
        formula = suffix ? "#{dep.name}@#{suffix}" : dep.name
        return if brew_installed?(formula)

        spec = dep.metadata["tap"] ? "#{dep.metadata["tap"]}/#{formula}" : formula
        run_brew_install(dep.name, spec)
      end

      # Install a Homebrew cask.
      #
      # @param dep [Dependency]
      # @raise [InstallError] if brew install --cask fails
      sig { params(dep: Dependency).void }
      def install_cask(dep)
        return if brew_installed?(dep.name)
        run_brew_install(dep.name, "--cask #{dep.name}")
      end

      # Check if a formula/cask is already installed.
      #
      # @param name [String] formula or cask name
      # @return [Boolean, nil] nil when the brew command itself cannot run
      sig { params(name: String).returns(T.nilable(T::Boolean)) }
      def brew_installed?(name)
        system("brew list #{name} >/dev/null 2>&1")
      end

      # Run `brew install` with the given spec.
      #
      # @param name [String] dependency name (for error messages)
      # @param spec [String] full install spec (e.g. "cmake@3.31.4")
      # @raise [InstallError] if brew exits non-zero
      sig { params(name: String, spec: String).void }
      def run_brew_install(name, spec)
        _out, err, status = T.unsafe(Open3).capture3("brew", "install", *spec.split)
        raise InstallError, "brew install #{spec} failed: #{err}" unless status.success?
      end
    end
  end
end

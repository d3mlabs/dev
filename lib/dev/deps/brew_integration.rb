# frozen_string_literal: true

require "open3"
require_relative "integration"
require_relative "dependency"

module Dev
  module Deps
    # Lifecycle handler for Homebrew dependencies.
    #
    # install_all:
    #   1. Filters deps by env scope (skip env-scoped deps not matching current env)
    #   2. Installs each formula/cask via brew
    #
    # Env follows Bundler's model: env controls inclusion (install or skip),
    # not versioning. All versions are universal.
    class BrewIntegration < Integration
      class InstallError < StandardError; end

      # @param repository [Repository] source adapter (BrewRepository)
      # @param cache      [Cache]      shared download cache
      # @param env        [String, nil] current environment ("ci", "dev", or nil for auto-detect)
      def initialize(repository:, cache:, env: nil)
        @env = env || detect_env
        super(repository:, cache:)
      end

      # Install all brew dependencies, skipping env-scoped deps that don't
      # match the current environment.
      #
      # @param dependencies [Array<Dependency>] brew deps to install
      def install_all(dependencies)
        dependencies.each do |dep|
          next if skip_for_env?(dep)

          if dep.metadata["cask"]
            install_cask(dep)
          else
            install_formula(dep)
          end
        end
      end

      private

      # Check if a dep should be skipped based on env scoping.
      #
      # @param dep [Dependency]
      # @return [Boolean]
      def skip_for_env?(dep)
        dep_env = dep.metadata["env"]
        return false if dep_env.nil?
        dep_env != @env
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
        true
      end

      # Detect the current environment based on CI/platform signals.
      #
      # @return [String] "ci" or "dev"
      def detect_env
        ci_like = ENV["CI"].to_s =~ /\A(true|1)\z/i
        linux = RUBY_PLATFORM.to_s.include?("linux")
        (ci_like || linux) ? "ci" : "dev"
      end
    end
  end
end

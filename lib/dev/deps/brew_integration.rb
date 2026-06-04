# frozen_string_literal: true

require "open3"
require_relative "integration"
require_relative "dependency"

module Dev
  module Deps
    # Lifecycle handler for Homebrew dependencies.
    #
    # install_all installs each formula/cask via brew.
    #
    # Env filtering (install vs skip based on ci/dev) is the caller's
    # responsibility — only pass deps that should be installed.
    class BrewIntegration < Integration
      class InstallError < StandardError; end

      # Install all brew dependencies.
      #
      # @param dependencies [Array<Dependency>] brew deps to install
      def install_all(dependencies)
        dependencies.each do |dep|
          if dep.metadata["cask"]
            install_cask(dep)
          else
            install_formula(dep)
          end
        end
      end

      private

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

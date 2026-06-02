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
      # @param env [String, nil] current environment ("ci", "dev", or nil for auto-detect)
      def initialize(repository:, cache:, env: nil)
        @env = env || detect_env
        super(repository: repository, cache: cache)
      end

      def install_all(dependencies, root:)
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

      def skip_for_env?(dep)
        dep_env = dep.metadata["env"]
        return false if dep_env.nil?
        dep_env != @env
      end

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

      def install_cask(dep)
        return if brew_installed?(dep.name)
        run_brew_install(dep.name, "--cask #{dep.name}")
      end

      def brew_installed?(name)
        system("brew list #{name} >/dev/null 2>&1")
      end

      def run_brew_install(name, spec)
        _out, err, status = Open3.capture3("brew", "install", *spec.split)
        raise "brew install #{spec} failed: #{err}" unless status.success?
        true
      end

      def detect_env
        ci_like = ENV["CI"].to_s =~ /\A(true|1)\z/i
        linux = RUBY_PLATFORM.to_s.include?("linux")
        (ci_like || linux) ? "ci" : "dev"
      end
    end
  end
end

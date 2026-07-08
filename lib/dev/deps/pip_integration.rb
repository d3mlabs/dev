# frozen_string_literal: true

require "open3"
require "pathname"
require_relative "integration"
require_relative "dependency"

module Dev
  module Deps
    # Lifecycle handler for pip dependencies.
    #
    # Installs each locked package into the project-local venv (.venv) that
    # ShadowenvPython provisions — the Python analogue of LuaRocks installing
    # into lua_modules/. The venv is ensured here (created if absent) so
    # `dev install-deps` works on a fresh clone, before any command has run
    # ShadowenvPython.setup!. pip resolves the transitive tree at install.
    class PipIntegration < Integration
      class InstallError < StandardError; end
      class MissingVersionError < StandardError; end

      # @param repository    [Repository] source adapter for pip deps
      # @param cache         [Cache]      shared download cache (unused; pip caches)
      # @param project_root  [Pathname]   project root (holds the .venv)
      # @param python_version [String, nil] the `python` toolchain version to build
      #   the venv with; required whenever there are pip deps to install
      def initialize(repository:, cache:, project_root:, python_version: nil)
        super(repository:, cache:)
        @project_root = Pathname(project_root)
        @python_version = python_version
      end

      # Install all pip deps into the project venv.
      #
      # @param dependencies [Array<Dependency>] pip deps to install
      # @raise [MissingVersionError] if pip deps exist but no `python` version is set
      # @raise [InstallError] if a pip install fails
      def install_all(dependencies)
        return if dependencies.empty?

        version = @python_version.to_s.strip
        raise MissingVersionError, "pip dependencies declared but no `python` version set in dependencies.rb" if version.empty?

        require "shadowenv_python"
        ShadowenvPython.ensure_venv!(python_version: version, project_root: @project_root)

        pip = @project_root / ShadowenvPython::VENV_DIR / "bin" / "pip"
        dependencies.each { |dep| run_pip_install(pip, dep) }
      end

      private

      # @param pip [Pathname] the venv's pip executable
      # @param dep [Dependency] dependency to install (exact version when pinned)
      # @raise [InstallError] if pip install fails
      def run_pip_install(pip, dep)
        spec = dep.version ? "#{dep.name}==#{dep.version}" : dep.name
        _out, err, status = Open3.capture3(pip.to_s, "install", spec)
        raise InstallError, "pip install #{spec} failed: #{err}" unless status.success?
      end
    end
  end
end

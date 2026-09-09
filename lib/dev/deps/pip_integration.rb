# typed: strict
# frozen_string_literal: true

require "open3"
require "pathname"
require "dev/shadowenv_python"
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
      extend T::Sig

      class InstallError < StandardError; end
      class MissingVersionError < StandardError; end

      # @param repository    [Repository, nil]  source adapter for pip deps
      # @param cache         [Cache, nil]       shared download cache (unused; pip caches)
      # @param project_root  [String, Pathname] project root (holds the .venv)
      # @param python_version [String, nil] the `python` toolchain version to build
      #   the venv with; required whenever there are pip deps to install
      sig do
        params(
          repository: T.nilable(Repository),
          cache: T.nilable(Cache),
          project_root: T.any(String, Pathname),
          python_version: T.nilable(String),
        ).void
      end
      def initialize(repository:, cache:, project_root:, python_version: nil)
        super(repository:, cache:)
        @project_root = T.let(Pathname(project_root), Pathname)
        @python_version = python_version
      end

      # Install all pip deps into the project venv.
      #
      # @param dependencies [Array<Dependency>] pip deps to install
      # @raise [MissingVersionError] if pip deps exist but no `python` version is set
      # @raise [InstallError] if a pip install fails
      sig { params(dependencies: T::Array[Dependency]).void }
      def install_all(dependencies)
        return if dependencies.empty?

        version = @python_version.to_s.strip
        raise MissingVersionError, "pip dependencies declared but no `python` version set in dependencies.rb" if version.empty?

        ShadowenvPython.ensure_venv!(python_version: version, project_root: @project_root)

        # Invoke `python -m pip` (not the `pip` console script): ensurepip always
        # provides the module, but the bin/pip wrapper can be absent on a venv
        # built by a Homebrew interpreter, which would fail with ENOENT.
        python = @project_root / ShadowenvPython::VENV_DIR / "bin" / "python"
        dependencies.each { |dep| run_pip_install(python, dep) }
      end

      private

      # @param python [Pathname] the venv's python interpreter
      # @param dep [Dependency] dependency to install (exact version when pinned)
      # @raise [InstallError] if pip install fails
      sig { params(python: Pathname, dep: Dependency).void }
      def run_pip_install(python, dep)
        spec = dep.version ? "#{dep.name}==#{dep.version}" : dep.name
        _out, err, status = Open3.capture3(python.to_s, "-m", "pip", "install", spec)
        raise InstallError, "pip install #{spec} failed: #{err}" unless status.success?
      end
    end
  end
end

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
    # Installs each locked package into the project-local venv (.venv) —
    # the Python analogue of LuaRocks installing into lua_modules/. The venv
    # is the locked Python's: the :python pin's activation builds it on the
    # installed keg (ShadowenvPython.activate!), in brew's batch ahead of
    # this one, so by the time pip deps install the venv is there and runs
    # the pinned interpreter. pip resolves the transitive tree at install,
    # and downloads into the store's pip tool cache (PIP_CACHE_DIR) — pip
    # owns the fetch and the install; dev names where the cache lives.
    class PipIntegration < Integration
      extend T::Sig

      class InstallError < StandardError; end

      # pip deps are locked but the project has no venv: nothing declared a
      # `python`, so no interpreter pin built one.
      class MissingVenvError < StandardError; end

      TOOL = "pip"

      # @param repository    [Repository, nil]  source adapter for pip deps
      # @param store         [ArtifactStore, nil] the store whose pip tool cache pip downloads into
      # @param project_root  [String, Pathname] project root (holds the .venv)
      sig do
        params(
          repository: T.nilable(Repository),
          store: T.nilable(ArtifactStore),
          project_root: T.any(String, Pathname),
        ).void
      end
      def initialize(repository:, store:, project_root:)
        super(repository:, store:)
        @project_root = T.let(Pathname(project_root), Pathname)
      end

      # Install all pip deps into the project venv.
      #
      # @param dependencies [Array<Dependency>] pip deps to install
      # @raise [MissingVenvError] if pip deps exist but the project has no venv
      # @raise [InstallError] if a pip install fails
      sig { params(dependencies: T::Array[Dependency]).void }
      def install_all(dependencies)
        return if dependencies.empty?

        # Invoke `python -m pip` (not the `pip` console script): ensurepip always
        # provides the module, but the bin/pip wrapper can be absent on a venv
        # built by a Homebrew interpreter, which would fail with ENOENT.
        python = @project_root / ShadowenvPython::VENV_DIR / "bin" / "python"
        unless python.executable?
          raise MissingVenvError,
            "pip dependencies are locked but #{@project_root / ShadowenvPython::VENV_DIR} has no interpreter: " \
              "declare `python \"<minor>\"` in dependencies.rb and run dev deps update, then dev up"
        end

        dependencies.each { |dep| run_pip_install(python, dep) }
      end

      private

      # @param python [Pathname] the venv's python interpreter
      # @param dep [Dependency] dependency to install (exact version when pinned)
      # @raise [InstallError] if pip install fails
      sig { params(python: Pathname, dep: Dependency).void }
      def run_pip_install(python, dep)
        spec = dep.version ? "#{dep.name}==#{dep.version}" : dep.name
        env = { "PIP_CACHE_DIR" => store!.tool_cache(TOOL).to_s }
        _out, err, status = Open3.capture3(env, python.to_s, "-m", "pip", "install", spec)
        raise InstallError, "pip install #{spec} failed: #{err}" unless status.success?
      end
    end
  end
end

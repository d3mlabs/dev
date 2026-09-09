# typed: strict
# frozen_string_literal: true

require "open3"
require "pathname"
require_relative "integration"
require_relative "dependency"

module Dev
  module Deps
    # Lifecycle handler for LuaRocks dependencies.
    #
    # Installs each dep via `luarocks install <name> <version> --tree <root>/lua_modules`.
    # Project-local install directory (`lua_modules/`) keeps deps isolated.
    class LuaRocksIntegration < Integration
      extend T::Sig

      class InstallError < StandardError; end

      INSTALL_DIR = "lua_modules"

      # @param repository    [Repository, nil]  source adapter for luarocks deps
      # @param cache         [Cache, nil]       shared download cache
      # @param project_root  [String, Pathname] project root directory
      sig do
        params(
          repository: T.nilable(Repository),
          cache: T.nilable(Cache),
          project_root: T.any(String, Pathname),
        ).void
      end
      def initialize(repository:, cache:, project_root:)
        super(repository:, cache:)
        @project_root = T.let(Pathname(project_root), Pathname)
      end

      # Install all LuaRocks dependencies into the project-local tree.
      #
      # @param dependencies [Array<Dependency>] luarocks deps to install
      sig { params(dependencies: T::Array[Dependency]).void }
      def install_all(dependencies)
        tree = @project_root / INSTALL_DIR
        dependencies.each do |dep|
          run_luarocks_install(dep, tree)
        end
      end

      private

      # @param dep  [Dependency] dependency to install
      # @param tree [Pathname]   luarocks --tree path
      # @raise [InstallError] if luarocks install command fails
      sig { params(dep: Dependency, tree: Pathname).void }
      def run_luarocks_install(dep, tree)
        _out, err, status = Open3.capture3(
          "luarocks", "install", dep.name, dep.version, "--tree", tree.to_s,
        )
        raise InstallError, "luarocks install #{dep.name} #{dep.version} failed: #{err}" unless status.success?
      end
    end
  end
end

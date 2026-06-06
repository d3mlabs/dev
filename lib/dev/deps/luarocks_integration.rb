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
      class InstallError < StandardError; end

      INSTALL_DIR = "lua_modules"

      # @param repository    [Repository] source adapter for luarocks deps
      # @param cache         [Cache]      shared download cache
      # @param project_root  [Pathname]   project root directory
      def initialize(repository:, cache:, project_root:)
        super(repository:, cache:)
        @project_root = Pathname(project_root)
      end

      # Install all LuaRocks dependencies into the project-local tree.
      #
      # @param dependencies [Array<Dependency>] luarocks deps to install
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
      def run_luarocks_install(dep, tree)
        _out, err, status = Open3.capture3(
          "luarocks", "install", dep.name, dep.version, "--tree", tree.to_s,
        )
        raise InstallError, "luarocks install #{dep.name} #{dep.version} failed: #{err}" unless status.success?
      end
    end
  end
end

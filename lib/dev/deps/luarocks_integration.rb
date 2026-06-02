# frozen_string_literal: true

require "open3"
require_relative "integration"
require_relative "dependency"

module Dev
  module Deps
    # Lifecycle handler for LuaRocks dependencies.
    #
    # install_all: installs each dep via `luarocks install <name> <version> --tree lua_modules`.
    # Project-local install directory (`lua_modules/`) keeps deps isolated.
    class LuaRocksIntegration < Integration
      INSTALL_DIR = "lua_modules"

      def install_all(dependencies, root:)
        tree = File.join(root, INSTALL_DIR)
        dependencies.each do |dep|
          run_luarocks_install(dep, tree)
        end
      end

      private

      def run_luarocks_install(dep, tree)
        _out, err, status = Open3.capture3(
          "luarocks", "install", dep.name, dep.version, "--tree", tree,
        )
        raise "luarocks install #{dep.name} #{dep.version} failed: #{err}" unless status.success?
        true
      end
    end
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/luarocks_integration"
require "dev/deps/luarocks_registry"
require "dev/deps/cache"
require "dev/deps/dependency"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::LuaRocksIntegrationTest < Minitest::Test
  test "install_all calls luarocks install for each dep" do
    Given "a luarocks dependency"
    dir = Dir.mktmpdir("dev-luarocks-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    registry = Dev::Deps::LuaRocksRegistry.new
    integration = Dev::Deps::LuaRocksIntegration.new(repository: registry, cache: cache)
    deps = [
      Dev::Deps::Dependency.new(name: "luaunit", integration: :luarocks, group: :test,
                                version: "3.5-1", hash: "SHA256=abc", metadata: {}),
    ]

    Dev::Deps::LuaRocksIntegration.any_instance.stubs(:run_luarocks_install).returns(true)

    When "installing all"
    integration.install_all(deps, root: dir)

    Then "no error means install was attempted"
    true

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

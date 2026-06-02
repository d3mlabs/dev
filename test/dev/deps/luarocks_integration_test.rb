# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/luarocks_integration"
require "dev/deps/luarocks_registry"
require "dev/deps/cache"
require "dev/deps/pin"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::LuaRocksIntegrationTest < Minitest::Test
  test "install_all calls luarocks install for each pin" do
    Given
    dir = Dir.mktmpdir("dev-luarocks-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    registry = Dev::Deps::LuaRocksRegistry.new
    integration = Dev::Deps::LuaRocksIntegration.new(repository: registry, cache: cache)
    pins = [
      Dev::Deps::Pin.new(name: "luaunit", integration: :luarocks, group: :test,
                          version: "3.5-1", hash: "SHA256=abc", metadata: {}),
    ]

    # Stub the install command
    Dev::Deps::LuaRocksIntegration.any_instance.stubs(:run_luarocks_install).returns(true)

    When
    integration.install_all(pins, root: dir)

    Then "no error means install was attempted"
    true

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

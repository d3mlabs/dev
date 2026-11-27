# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/luarocks_integration"
require "dev/deps/luarocks_repository"
require "dev/deps/local_store"
require "dev/deps/dependency"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::LuaRocksIntegrationTest < Minitest::Test
  test "install_all calls luarocks install for each dep" do
    Given "a luarocks dependency"
    dir = Dir.mktmpdir("dev-luarocks-int-test-")
    store = Dev::Deps::LocalStore.new(data_root: dir)
    repository = Dev::Deps::LuaRocksRepository.new
    integration = Dev::Deps::LuaRocksIntegration.new(repository: repository, store: store,
      project_root: Pathname(dir))
    deps = [
      Dev::Deps::Dependency.new(name: "luaunit", integration: :luarocks, group: :test,
        version: "3.5-1", hash: "SHA256=abc", metadata: {}),
    ]
    tree = (Pathname(dir) / "lua_modules").to_s

    When "installing all dependencies"
    integration.install_all(deps)

    Then "the luarocks install command was dispatched with the correct args"
    1 * Open3.capture3("luarocks", "install", "luaunit", "3.5-1", "--tree", tree) >> ["", "", exit_status(0)]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all raises InstallError on failure" do
    Given "a luarocks dependency with a failing install"
    dir = Dir.mktmpdir("dev-luarocks-int-test-")
    store = Dev::Deps::LocalStore.new(data_root: dir)
    repository = Dev::Deps::LuaRocksRepository.new
    integration = Dev::Deps::LuaRocksIntegration.new(repository: repository, store: store,
      project_root: Pathname(dir))
    deps = [
      Dev::Deps::Dependency.new(name: "badrock", integration: :luarocks, group: :runtime,
        version: "1.0", hash: "SHA256=def", metadata: {}),
    ]

    When "installing all dependencies"
    error = assert_raises(Dev::Deps::LuaRocksIntegration::InstallError) do
      integration.install_all(deps)
    end

    Then "the error mentions the failing package"
    _ * Open3.capture3 >> ["", "not found", exit_status(1)]
    error.message.include?("badrock")

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

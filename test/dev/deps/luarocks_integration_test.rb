# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/luarocks_integration"
require "dev/deps/luarocks_repository"
require "dev/deps/cache"
require "dev/deps/dependency"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::LuaRocksIntegrationTest < Minitest::Test
  test "install_all calls luarocks install for each dep" do
    Given "a luarocks dependency and a stubbed Open3"
    dir = Dir.mktmpdir("dev-luarocks-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    repository = Dev::Deps::LuaRocksRepository.new
    integration = Dev::Deps::LuaRocksIntegration.new(repository: repository, cache: cache,
                                                     project_root: Pathname(dir))
    deps = [
      Dev::Deps::Dependency.new(name: "luaunit", integration: :luarocks, group: :test,
                                version: "3.5-1", hash: "SHA256=abc", metadata: {}),
    ]
    tree = (Pathname(dir) / "lua_modules").to_s
    Open3.expects(:capture3)
         .with("luarocks", "install", "luaunit", "3.5-1", "--tree", tree)
         .returns(["", "", stub(success?: true)])

    When "installing all dependencies"
    integration.install_all(deps)

    Then "the luarocks install command was dispatched with the correct args"
    true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all raises InstallError on failure" do
    Given "a luarocks dependency with a failing install"
    dir = Dir.mktmpdir("dev-luarocks-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    repository = Dev::Deps::LuaRocksRepository.new
    integration = Dev::Deps::LuaRocksIntegration.new(repository: repository, cache: cache,
                                                     project_root: Pathname(dir))
    deps = [
      Dev::Deps::Dependency.new(name: "badrock", integration: :luarocks, group: :runtime,
                                version: "1.0", hash: "SHA256=def", metadata: {}),
    ]
    failed_status = stub(success?: false)
    Open3.stubs(:capture3).returns(["", "not found", failed_status])

    When "installing all dependencies"
    error = assert_raises(Dev::Deps::LuaRocksIntegration::InstallError) do
      integration.install_all(deps)
    end

    Then "the error mentions the failing package"
    error.message.include?("badrock")

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

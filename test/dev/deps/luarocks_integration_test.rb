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
    Given
    dir = Dir.mktmpdir("dev-luarocks-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    repository = Dev::Deps::LuaRocksRepository.new
    integration = Dev::Deps::LuaRocksIntegration.new(repository: repository, cache: cache,
                                                     project_root: Pathname(dir))
    deps = [
      Dev::Deps::Dependency.new(name: "luaunit", integration: :luarocks, group: :test,
                                version: "3.5-1", hash: "SHA256=abc", metadata: {}),
    ]
    installed = []
    integration.define_singleton_method(:run_luarocks_install) { |dep, _tree| installed << dep.name }

    When
    integration.install_all(deps)

    Then
    installed == ["luaunit"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all raises InstallError on failure" do
    Given
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

    When
    error = assert_raises(Dev::Deps::LuaRocksIntegration::InstallError) do
      integration.install_all(deps)
    end

    Then
    error.message.include?("badrock")

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

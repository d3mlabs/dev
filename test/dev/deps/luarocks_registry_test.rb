# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/luarocks_registry"
require "dev/deps/cache"
require "tmpdir"
require "digest"

transform!(RSpock::AST::Transformation)
class Dev::Deps::LuaRocksRegistryTest < Minitest::Test
  test "fetch parses luarocks search output and returns a Dependency" do
    Given "a luarocks package identifier"
    dir = Dir.mktmpdir("dev-luarocks-reg-test-")
    registry = Dev::Deps::LuaRocksRegistry.new
    search_output = "luaunit\n   3.5-1 (src) - https://luarocks.org\n   3.4-1 (src) - https://luarocks.org\n"

    fake_rock = File.join(dir, "luaunit-3.5-1.src.rock")
    File.write(fake_rock, "fake rock content")

    Open3.stubs(:capture3)
         .with("luarocks", "search", "luaunit", "--porcelain")
         .returns([search_output, "", stub(success?: true)])
    registry.stubs(:download_rock).returns(fake_rock)

    When "fetching the dependency"
    dep = registry.fetch(
      "name" => "luaunit",
      "integration" => "luarocks",
      "group" => "test",
      "constraint" => ">=3.5",
    )

    Then
    dep.name == "luaunit"
    dep.integration == :luarocks
    dep.group == :test
    dep.version == "3.5-1"
    dep.hash.start_with?("SHA256=")

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

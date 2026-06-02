# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/luarocks_registry"
require "dev/deps/cache"
require "tmpdir"
require "digest"

transform!(RSpock::AST::Transformation)
class Dev::Deps::LuaRocksRegistryTest < Minitest::Test
  test "resolve parses luarocks search output and returns a Pin" do
    Given
    dir = Dir.mktmpdir("dev-luarocks-reg-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    registry = Dev::Deps::LuaRocksRegistry.new
    search_output = "luaunit\n   3.5-1 (src) - https://luarocks.org\n   3.4-1 (src) - https://luarocks.org\n"

    # Create a fake rock for download + hash
    fake_rock = File.join(dir, "luaunit-3.5-1.src.rock")
    File.write(fake_rock, "fake rock content")

    Open3.stubs(:capture3)
         .with("luarocks", "search", "luaunit", "--porcelain")
         .returns([search_output, "", stub(success?: true)])
    registry.stubs(:download_rock).returns(fake_rock)

    When
    pin = registry.resolve(
      "luaunit",
      { "integration" => "luarocks", "group" => "test", "constraint" => ">=3.5" },
      cache: cache,
    )

    Then
    pin.name == "luaunit"
    pin.integration == :luarocks
    pin.group == :test
    pin.version == "3.5-1"
    pin.hash.start_with?("SHA256=")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "resolve caches the downloaded rock" do
    Given
    dir = Dir.mktmpdir("dev-luarocks-reg-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    registry = Dev::Deps::LuaRocksRegistry.new
    search_output = "luaunit\n   3.5-1 (src) - https://luarocks.org\n"

    fake_rock = File.join(dir, "luaunit-3.5-1.src.rock")
    File.write(fake_rock, "fake rock for cache test")
    expected_hash = "SHA256=#{Digest::SHA256.file(fake_rock).hexdigest}"

    Open3.stubs(:capture3)
         .with("luarocks", "search", "luaunit", "--porcelain")
         .returns([search_output, "", stub(success?: true)])
    registry.stubs(:download_rock).returns(fake_rock)

    When
    pin = registry.resolve("luaunit", { "integration" => "luarocks", "group" => "test" }, cache: cache)

    Then
    cache.has?(expected_hash)

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

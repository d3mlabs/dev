# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/luarocks_repository"
require "dev/deps/cache"
require "tmpdir"
require "digest"

transform!(RSpock::AST::Transformation)
class Dev::Deps::LuaRocksRepositoryTest < Minitest::Test
  test "fetch parses luarocks search output and returns a Dependency" do
    Given
    dir = Dir.mktmpdir("dev-luarocks-reg-test-")
    repository = Dev::Deps::LuaRocksRepository.new
    search_output = "luaunit\n   3.5-1 (src) - https://luarocks.org\n   3.4-1 (src) - https://luarocks.org\n"

    fake_rock = File.join(dir, "luaunit-3.5-1.src.rock")
    File.write(fake_rock, "fake rock content")

    Open3.stubs(:capture3)
         .with("luarocks", "search", "luaunit", "--porcelain")
         .returns([search_output, "", stub(success?: true)])
    repository.stubs(:download_rock).returns(fake_rock)

    When
    dep = repository.fetch(
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

  test "fetch raises SearchError when luarocks search fails" do
    Given
    repository = Dev::Deps::LuaRocksRepository.new
    failed_status = stub(success?: false)
    Open3.stubs(:capture3)
         .with("luarocks", "search", "missing", "--porcelain")
         .returns(["", "error", failed_status])

    When
    error = assert_raises(Dev::Deps::LuaRocksRepository::SearchError) do
      repository.fetch("name" => "missing", "integration" => "luarocks",
                        "group" => "runtime", "constraint" => ">=1.0")
    end

    Then
    error.message.include?("missing")
  end

  test "fetch raises NoVersionError when no versions found" do
    Given
    repository = Dev::Deps::LuaRocksRepository.new
    Open3.stubs(:capture3)
         .with("luarocks", "search", "empty", "--porcelain")
         .returns(["empty\n", "", stub(success?: true)])

    When
    error = assert_raises(Dev::Deps::LuaRocksRepository::NoVersionError) do
      repository.fetch("name" => "empty", "integration" => "luarocks",
                        "group" => "runtime", "constraint" => ">=1.0")
    end

    Then
    error.message.include?("empty")
  end
end

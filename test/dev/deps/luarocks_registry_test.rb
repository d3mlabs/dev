# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/luarocks_repository"
require "dev/deps/cache"
require "tmpdir"
require "digest"

transform!(RSpock::AST::Transformation)
class Dev::Deps::LuaRocksRepositoryTest < Minitest::Test
  test "find reports the manifest's versions, deduplicated, facts only" do
    Given "a stubbed luarocks search listing two versions"
    repository = Dev::Deps::LuaRocksRepository.new
    search_output = "luaunit\n   3.5-1 (src) - https://luarocks.org\n   " \
      "3.5-1 (rockspec) - https://luarocks.org\n   3.4-1 (src) - https://luarocks.org\n"
    Open3.stubs(:capture3)
         .with("luarocks", "search", "luaunit", "--porcelain")
         .returns([search_output, "", stub(success?: true)])

    When "finding the package"
    package = repository.find(Dev::Deps::PackageId.new(integration: :luarocks, name: "luaunit"))

    Then "the universe holds bare versions — no digests, no edges"
    package.versions.map(&:version) == ["3.5-1", "3.4-1"]
    package.version("3.5-1").digest.nil?
    package.version("3.5-1").dependencies == []
  end

  test "find raises RockNotFoundError, a PackageNotFoundError, on empty search" do
    Given "a luarocks search that returns no version lines"
    repository = Dev::Deps::LuaRocksRepository.new
    Open3.stubs(:capture3)
         .with("luarocks", "search", "missing", "--porcelain")
         .returns(["missing\n", "", stub(success?: true)])

    When "finding the package"
    repository.find(Dev::Deps::PackageId.new(integration: :luarocks, name: "missing"))

    Then
    raises Dev::Deps::Repository::PackageNotFoundError
  end

  test "find raises SearchError when luarocks search fails" do
    Given "a luarocks search that returns a non-zero exit"
    repository = Dev::Deps::LuaRocksRepository.new
    Open3.stubs(:capture3)
         .with("luarocks", "search", "broken", "--porcelain")
         .returns(["", "error", stub(success?: false)])

    When "finding the package"
    repository.find(Dev::Deps::PackageId.new(integration: :luarocks, name: "broken"))

    Then
    raises Dev::Deps::LuaRocksRepository::SearchError
  end

  test "fetch parses luarocks search output and returns a Dependency" do
    Given "a stubbed luarocks search and download at the Open3 boundary"
    repository = Dev::Deps::LuaRocksRepository.new
    search_output = "luaunit\n   3.5-1 (src) - https://luarocks.org\n   3.4-1 (src) - https://luarocks.org\n"

    Open3.stubs(:capture3)
         .with("luarocks", "search", "luaunit", "--porcelain")
         .returns([search_output, "", stub(success?: true)])
    Open3.stubs(:capture3)
         .with("luarocks", "download", "luaunit", "3.5-1", "--source", anything)
         .returns(["", "", stub(success?: true)])

    When "fetching the dependency"
    dep = repository.fetch(
      "name" => "luaunit",
      "integration" => "luarocks",
      "group" => "test",
      "constraint" => ">=3.5",
    )

    Then "the dependency has the resolved version and integrity hash"
    dep.name == "luaunit"
    dep.integration == :luarocks
    dep.group == :test
    dep.version == "3.5-1"
    dep.hash.start_with?("SHA256=")
  end

  test "fetch raises SearchError when luarocks search fails" do
    Given "a luarocks search that returns a non-zero exit"
    repository = Dev::Deps::LuaRocksRepository.new
    failed_status = stub(success?: false)
    Open3.stubs(:capture3)
         .with("luarocks", "search", "missing", "--porcelain")
         .returns(["", "error", failed_status])

    When "fetching the dependency"
    error = assert_raises(Dev::Deps::LuaRocksRepository::SearchError) do
      repository.fetch("name" => "missing", "integration" => "luarocks",
        "group" => "runtime", "constraint" => ">=1.0")
    end

    Then "the error mentions the package name"
    error.message.include?("missing")
  end

  test "fetch raises NoVersionError when no versions found" do
    Given "a luarocks search that returns no version lines"
    repository = Dev::Deps::LuaRocksRepository.new
    Open3.stubs(:capture3)
         .with("luarocks", "search", "empty", "--porcelain")
         .returns(["empty\n", "", stub(success?: true)])

    When "fetching the dependency"
    error = assert_raises(Dev::Deps::LuaRocksRepository::NoVersionError) do
      repository.fetch("name" => "empty", "integration" => "luarocks",
        "group" => "runtime", "constraint" => ">=1.0")
    end

    Then "the error mentions the package name"
    error.message.include?("empty")
  end
end

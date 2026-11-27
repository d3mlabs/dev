# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/luarocks_repository"
require "tmpdir"
require "digest"

transform!(RSpock::AST::Transformation)
class Dev::Deps::LuaRocksRepositoryTest < Minitest::Test
  test "find reports the manifest's versions, deduplicated, facts only" do
    Given "a luarocks search listing two versions"
    repository = Dev::Deps::LuaRocksRepository.new
    search_output = "luaunit\n   3.5-1 (src) - https://luarocks.org\n   " \
      "3.5-1 (rockspec) - https://luarocks.org\n   3.4-1 (src) - https://luarocks.org\n"

    When "finding the package"
    package = repository.find(Dev::Deps::PackageId.new(integration: :luarocks, name: "luaunit"))

    Then "the universe holds bare versions — no digests, no edges"
    _ * Open3.capture3("luarocks", "search", "luaunit", "--porcelain") >> [search_output, "", exit_status(0)]
    package.versions.map(&:version) == ["3.5-1", "3.4-1"]
    package.version("3.5-1").digest.nil?
    package.version("3.5-1").source == "3.5-1"
    package.version("3.5-1").declarations == Dev::Deps::Declarations::ToolOwned.new
  end

  test "find raises RockNotFoundError, a PackageNotFoundError, on empty search" do
    Given "a luarocks search that returns no version lines"
    repository = Dev::Deps::LuaRocksRepository.new

    When "finding the package"
    repository.find(Dev::Deps::PackageId.new(integration: :luarocks, name: "missing"))

    Then
    _ * Open3.capture3("luarocks", "search", "missing", "--porcelain") >> ["missing\n", "", exit_status(0)]
    raises Dev::Deps::Repository::PackageNotFoundError
  end

  test "find raises SearchError when luarocks search fails" do
    Given "a luarocks search that returns a non-zero exit"
    repository = Dev::Deps::LuaRocksRepository.new

    When "finding the package"
    repository.find(Dev::Deps::PackageId.new(integration: :luarocks, name: "broken"))

    Then
    _ * Open3.capture3("luarocks", "search", "broken", "--porcelain") >> ["", "error", exit_status(1)]
    raises Dev::Deps::LuaRocksRepository::SearchError
  end
end

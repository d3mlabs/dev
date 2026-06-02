# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/resolver"
require "dev/deps/repository"
require "dev/deps/dependency"
require "dev/deps/cache"
require "tmpdir"

# Stub repository that returns canned Dependencies without network calls.
class StubRepository < Dev::Deps::Repository
  def initialize(deps_by_name: {})
    @deps_by_name = deps_by_name
  end

  def fetch(id)
    @deps_by_name.fetch(id["name"])
  end
end

transform!(RSpock::AST::Transformation)
class Dev::Deps::ResolverTest < Minitest::Test
  test "resolves a flat list of deps with no transitive dependencies" do
    Given "two independent dependencies"
    boost = Dev::Deps::Dependency.new(name: "boost", integration: :cmake, group: :app,
                                      version: "sha1", hash: nil, metadata: {})
    gtest = Dev::Deps::Dependency.new(name: "gtest", integration: :cmake, group: :test,
                                      version: "sha2", hash: nil, metadata: {})
    repo = StubRepository.new(deps_by_name: { "boost" => boost, "gtest" => gtest })
    deps = [
      { name: "boost", integration: :cmake, constraint: {}, group: :app },
      { name: "gtest", integration: :cmake, constraint: {}, group: :test },
    ]
    resolver = Dev::Deps::Resolver.new(repositories: { cmake: repo })

    When "resolving"
    result = resolver.resolve(deps)

    Then
    result.size == 2
    result.map(&:name).sort == ["boost", "gtest"]
  end

  test "resolves transitive dependencies via Dependency#dependencies" do
    Given "a parent with a transitive child"
    child = Dev::Deps::Dependency.new(name: "child", integration: :luarocks, group: :test,
                                      version: "2.0", hash: "SHA256=bbb", metadata: {})
    parent = Dev::Deps::Dependency.new(name: "parent", integration: :luarocks, group: :test,
                                       version: "1.0", hash: "SHA256=aaa", metadata: {},
                                       dependencies: [{ name: "child", constraint: ">= 1.0" }])
    repo = StubRepository.new(deps_by_name: { "parent" => parent, "child" => child })
    deps = [
      { name: "parent", integration: :luarocks, constraint: {}, group: :test },
    ]
    resolver = Dev::Deps::Resolver.new(repositories: { luarocks: repo })

    When "resolving"
    result = resolver.resolve(deps)

    Then
    result.size == 2
    result.map(&:name).sort == ["child", "parent"]
  end

  test "does not duplicate already-resolved transitive deps" do
    Given "overlapping direct and transitive deps"
    a = Dev::Deps::Dependency.new(name: "a", integration: :cmake, group: :app,
                                  version: "1.0", hash: nil, metadata: {},
                                  dependencies: [{ name: "b", constraint: ">= 1.0" }])
    b = Dev::Deps::Dependency.new(name: "b", integration: :cmake, group: :app,
                                  version: "1.0", hash: nil, metadata: {})
    repo = StubRepository.new(deps_by_name: { "a" => a, "b" => b })
    deps = [
      { name: "a", integration: :cmake, constraint: {}, group: :app },
      { name: "b", integration: :cmake, constraint: {}, group: :app },
    ]
    resolver = Dev::Deps::Resolver.new(repositories: { cmake: repo })

    When "resolving"
    result = resolver.resolve(deps)

    Then
    result.size == 2
    result.map(&:name).sort == ["a", "b"]
  end

  test "handles deps with empty transitive dependencies" do
    Given "a dependency with no transitive deps"
    solo = Dev::Deps::Dependency.new(name: "solo", integration: :cmake, group: :app,
                                     version: "1.0", hash: nil, metadata: {})
    repo = StubRepository.new(deps_by_name: { "solo" => solo })
    deps = [{ name: "solo", integration: :cmake, constraint: {}, group: :app }]
    resolver = Dev::Deps::Resolver.new(repositories: { cmake: repo })

    When "resolving"
    result = resolver.resolve(deps)

    Then
    result.size == 1
    result[0].name == "solo"
  end
end

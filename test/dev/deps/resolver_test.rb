# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/resolver"
require "dev/deps/repository"
require "dev/deps/pin"
require "dev/deps/cache"
require "tmpdir"

# Stub repository that returns canned Pins without network calls.
class StubRepository < Dev::Deps::Repository
  def initialize(pins_by_name: {}, deps_by_name: {})
    @pins_by_name = pins_by_name
    @deps_by_name = deps_by_name
  end

  def resolve(name, constraint, cache:)
    @pins_by_name.fetch(name)
  end

  def dependencies(pin)
    @deps_by_name.fetch(pin.name, [])
  end
end

transform!(RSpock::AST::Transformation)
class Dev::Deps::ResolverTest < Minitest::Test
  test "resolves a flat list of deps with no transitive dependencies" do
    Given
    dir = Dir.mktmpdir("dev-resolver-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    boost_pin = Dev::Deps::Pin.new(name: "boost", integration: :cmake, group: :app,
                                    version: "sha1", hash: nil, metadata: {})
    gtest_pin = Dev::Deps::Pin.new(name: "gtest", integration: :cmake, group: :test,
                                    version: "sha2", hash: nil, metadata: {})
    repo = StubRepository.new(pins_by_name: { "boost" => boost_pin, "gtest" => gtest_pin })
    integrations = { cmake: stub(repository: repo) }
    deps = [
      { name: "boost", integration: :cmake, constraint: {}, group: :app },
      { name: "gtest", integration: :cmake, constraint: {}, group: :test },
    ]
    resolver = Dev::Deps::Resolver.new(integrations: integrations, cache: cache)

    When
    pins = resolver.resolve(deps)

    Then
    pins.size == 2
    pins.map(&:name).sort == ["boost", "gtest"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "resolves transitive dependencies from repositories that support them" do
    Given
    dir = Dir.mktmpdir("dev-resolver-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    parent_pin = Dev::Deps::Pin.new(name: "parent", integration: :luarocks, group: :test,
                                     version: "1.0", hash: "SHA256=aaa", metadata: {})
    child_pin = Dev::Deps::Pin.new(name: "child", integration: :luarocks, group: :test,
                                    version: "2.0", hash: "SHA256=bbb", metadata: {})
    repo = StubRepository.new(
      pins_by_name: { "parent" => parent_pin, "child" => child_pin },
      deps_by_name: { "parent" => [{ name: "child", constraint: ">= 1.0" }] },
    )
    integrations = { luarocks: stub(repository: repo) }
    deps = [
      { name: "parent", integration: :luarocks, constraint: {}, group: :test },
    ]
    resolver = Dev::Deps::Resolver.new(integrations: integrations, cache: cache)

    When
    pins = resolver.resolve(deps)

    Then
    pins.size == 2
    pins.map(&:name).sort == ["child", "parent"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "does not duplicate already-resolved transitive deps" do
    Given
    dir = Dir.mktmpdir("dev-resolver-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    a_pin = Dev::Deps::Pin.new(name: "a", integration: :cmake, group: :app,
                                version: "1.0", hash: nil, metadata: {})
    b_pin = Dev::Deps::Pin.new(name: "b", integration: :cmake, group: :app,
                                version: "1.0", hash: nil, metadata: {})
    repo = StubRepository.new(
      pins_by_name: { "a" => a_pin, "b" => b_pin },
      deps_by_name: { "a" => [{ name: "b", constraint: ">= 1.0" }] },
    )
    integrations = { cmake: stub(repository: repo) }
    deps = [
      { name: "a", integration: :cmake, constraint: {}, group: :app },
      { name: "b", integration: :cmake, constraint: {}, group: :app },
    ]
    resolver = Dev::Deps::Resolver.new(integrations: integrations, cache: cache)

    When
    pins = resolver.resolve(deps)

    Then
    pins.size == 2
    pins.map(&:name).sort == ["a", "b"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "handles repos returning empty transitive deps" do
    Given
    dir = Dir.mktmpdir("dev-resolver-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    pin = Dev::Deps::Pin.new(name: "solo", integration: :cmake, group: :app,
                              version: "1.0", hash: nil, metadata: {})
    repo = StubRepository.new(pins_by_name: { "solo" => pin }, deps_by_name: {})
    integrations = { cmake: stub(repository: repo) }
    deps = [{ name: "solo", integration: :cmake, constraint: {}, group: :app }]
    resolver = Dev::Deps::Resolver.new(integrations: integrations, cache: cache)

    When
    pins = resolver.resolve(deps)

    Then
    pins.size == 1
    pins[0].name == "solo"

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/resolver"
require "dev/deps/repository"
require "dev/deps/dependency"
require "dev/deps/dependency_declaration"
require "dev/deps/cache"
require "tmpdir"

# Stub repository that returns canned Dependencies without network calls.
# Records fetch IDs for assertion.
class StubRepository < Dev::Deps::Repository
  attr_reader :fetched_ids

  def initialize(deps_by_name: {})
    @deps_by_name = deps_by_name
    @fetched_ids = []
  end

  def fetch(id)
    @fetched_ids << id
    @deps_by_name.fetch(id["name"])
  end
end

# Records the declarations passed to the batch prepare hook.
class PreparingRepository < Dev::Deps::Repository
  attr_reader :prepared_with

  def initialize(deps_by_name: {})
    @deps_by_name = deps_by_name
    @prepared_with = nil
  end

  def prepare(declarations)
    @prepared_with = declarations
  end

  def fetch(id)
    @deps_by_name.fetch(id["name"])
  end
end

transform!(RSpock::AST::Transformation)
class Dev::Deps::ResolverTest < Minitest::Test
  test "calls prepare once per integration with that integration's declarations before fetching" do
    Given "a preparing repo with two declarations of its type"
    foo = Dev::Deps::Dependency.new(name: "foo", integration: :bundler, group: :app,
                                    version: "1.0", hash: nil, metadata: {})
    bar = Dev::Deps::Dependency.new(name: "bar", integration: :bundler, group: :test,
                                    version: "2.0", hash: nil, metadata: {})
    repo = PreparingRepository.new(deps_by_name: { "foo" => foo, "bar" => bar })
    declarations = [
      Dev::Deps::DependencyDeclaration.new(name: "foo", integration: :bundler, group: :app),
      Dev::Deps::DependencyDeclaration.new(name: "bar", integration: :bundler, group: :test),
    ]
    resolver = Dev::Deps::Resolver.new(repositories: { bundler: repo })

    When "resolving"
    result = resolver.resolve(declarations)

    Then "prepare received all bundler declarations and resolution still works"
    repo.prepared_with.map(&:name).sort == ["bar", "foo"]
    result.map(&:name).sort == ["bar", "foo"]
  end

  test "resolves a flat list of declarations with no transitive dependencies" do
    Given "two independent declarations"
    boost = Dev::Deps::Dependency.new(name: "boost", integration: :cmake, group: :app,
                                      version: "sha1", hash: nil, metadata: {})
    gtest = Dev::Deps::Dependency.new(name: "gtest", integration: :cmake, group: :test,
                                      version: "sha2", hash: nil, metadata: {})
    repo = StubRepository.new(deps_by_name: { "boost" => boost, "gtest" => gtest })
    declarations = [
      Dev::Deps::DependencyDeclaration.new(name: "boost", integration: :cmake, group: :app),
      Dev::Deps::DependencyDeclaration.new(name: "gtest", integration: :cmake, group: :test),
    ]
    resolver = Dev::Deps::Resolver.new(repositories: { cmake: repo })

    When "resolving"
    result = resolver.resolve(declarations)

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
    declarations = [
      Dev::Deps::DependencyDeclaration.new(name: "parent", integration: :luarocks, group: :test),
    ]
    resolver = Dev::Deps::Resolver.new(repositories: { luarocks: repo })

    When "resolving"
    result = resolver.resolve(declarations)

    Then
    result.size == 2
    result.map(&:name).sort == ["child", "parent"]
  end

  test "raises UnknownIntegrationError for unregistered integration" do
    Given "a declaration referencing an unregistered integration"
    resolver = Dev::Deps::Resolver.new(repositories: {})
    declarations = [
      Dev::Deps::DependencyDeclaration.new(name: "foo", integration: :unknown, group: :app),
    ]

    When "resolving"
    resolver.resolve(declarations)

    Then
    raises Dev::Deps::Resolver::UnknownIntegrationError
  end

  test "does not duplicate already-resolved transitive deps" do
    Given "overlapping direct and transitive deps"
    a = Dev::Deps::Dependency.new(name: "a", integration: :cmake, group: :app,
                                  version: "1.0", hash: nil, metadata: {},
                                  dependencies: [{ name: "b", constraint: ">= 1.0" }])
    b = Dev::Deps::Dependency.new(name: "b", integration: :cmake, group: :app,
                                  version: "1.0", hash: nil, metadata: {})
    repo = StubRepository.new(deps_by_name: { "a" => a, "b" => b })
    declarations = [
      Dev::Deps::DependencyDeclaration.new(name: "a", integration: :cmake, group: :app),
      Dev::Deps::DependencyDeclaration.new(name: "b", integration: :cmake, group: :app),
    ]
    resolver = Dev::Deps::Resolver.new(repositories: { cmake: repo })

    When "resolving"
    result = resolver.resolve(declarations)

    Then
    result.size == 2
    result.map(&:name).sort == ["a", "b"]
  end

  test "handles declarations with empty transitive dependencies" do
    Given "a declaration with no transitive deps"
    solo = Dev::Deps::Dependency.new(name: "solo", integration: :cmake, group: :app,
                                     version: "1.0", hash: nil, metadata: {})
    repo = StubRepository.new(deps_by_name: { "solo" => solo })
    declarations = [
      Dev::Deps::DependencyDeclaration.new(name: "solo", integration: :cmake, group: :app),
    ]
    resolver = Dev::Deps::Resolver.new(repositories: { cmake: repo })

    When "resolving"
    result = resolver.resolve(declarations)

    Then
    result.size == 1
    result[0].name == "solo"
  end

  test "resolves deep transitive chains beyond depth 1" do
    Given "A depends on B, B depends on C"
    c = Dev::Deps::Dependency.new(name: "c", integration: :luarocks, group: :app,
                                  version: "3.0", hash: "SHA256=ccc", metadata: {})
    b = Dev::Deps::Dependency.new(name: "b", integration: :luarocks, group: :app,
                                  version: "2.0", hash: "SHA256=bbb", metadata: {},
                                  dependencies: [{ name: "c", constraint: ">= 3.0" }])
    a = Dev::Deps::Dependency.new(name: "a", integration: :luarocks, group: :app,
                                  version: "1.0", hash: "SHA256=aaa", metadata: {},
                                  dependencies: [{ name: "b", constraint: ">= 2.0" }])
    repo = StubRepository.new(deps_by_name: { "a" => a, "b" => b, "c" => c })
    declarations = [
      Dev::Deps::DependencyDeclaration.new(name: "a", integration: :luarocks, group: :app),
    ]
    resolver = Dev::Deps::Resolver.new(repositories: { luarocks: repo })

    When "resolving"
    result = resolver.resolve(declarations)

    Then
    result.size == 3
    result.map(&:name).sort == ["a", "b", "c"]
  end

  test "resolves diamond dependencies without duplication" do
    Given "A depends on B and C, both depend on D"
    d = Dev::Deps::Dependency.new(name: "d", integration: :luarocks, group: :app,
                                  version: "1.0", hash: "SHA256=ddd", metadata: {})
    b = Dev::Deps::Dependency.new(name: "b", integration: :luarocks, group: :app,
                                  version: "1.0", hash: "SHA256=bbb", metadata: {},
                                  dependencies: [{ name: "d", constraint: ">= 1.0" }])
    c = Dev::Deps::Dependency.new(name: "c", integration: :luarocks, group: :app,
                                  version: "1.0", hash: "SHA256=ccc", metadata: {},
                                  dependencies: [{ name: "d", constraint: ">= 1.0" }])
    a = Dev::Deps::Dependency.new(name: "a", integration: :luarocks, group: :app,
                                  version: "1.0", hash: "SHA256=aaa", metadata: {},
                                  dependencies: [
                                    { name: "b", constraint: ">= 1.0" },
                                    { name: "c", constraint: ">= 1.0" },
                                  ])
    repo = StubRepository.new(deps_by_name: { "a" => a, "b" => b, "c" => c, "d" => d })
    declarations = [
      Dev::Deps::DependencyDeclaration.new(name: "a", integration: :luarocks, group: :app),
    ]
    resolver = Dev::Deps::Resolver.new(repositories: { luarocks: repo })

    When "resolving"
    result = resolver.resolve(declarations)

    Then
    result.size == 4
    result.map(&:name).sort == ["a", "b", "c", "d"]
  end

  test "terminates on cyclic transitive dependencies" do
    Given "A depends on B, B depends on A"
    a = Dev::Deps::Dependency.new(name: "a", integration: :cmake, group: :app,
                                  version: "1.0", hash: nil, metadata: {},
                                  dependencies: [{ name: "b", constraint: {} }])
    b = Dev::Deps::Dependency.new(name: "b", integration: :cmake, group: :app,
                                  version: "1.0", hash: nil, metadata: {},
                                  dependencies: [{ name: "a", constraint: {} }])
    repo = StubRepository.new(deps_by_name: { "a" => a, "b" => b })
    declarations = [
      Dev::Deps::DependencyDeclaration.new(name: "a", integration: :cmake, group: :app),
    ]
    resolver = Dev::Deps::Resolver.new(repositories: { cmake: repo })

    When "resolving"
    result = resolver.resolve(declarations)

    Then
    result.size == 2
    result.map(&:name).sort == ["a", "b"]
  end

  test "transitive dependencies inherit parent's group" do
    Given "a :test parent with a transitive child"
    child = Dev::Deps::Dependency.new(name: "child", integration: :luarocks, group: :test,
                                      version: "2.0", hash: "SHA256=bbb", metadata: {})
    parent = Dev::Deps::Dependency.new(name: "parent", integration: :luarocks, group: :test,
                                       version: "1.0", hash: "SHA256=aaa", metadata: {},
                                       dependencies: [{ name: "child", constraint: ">= 1.0" }])
    repo = StubRepository.new(deps_by_name: { "parent" => parent, "child" => child })
    declarations = [
      Dev::Deps::DependencyDeclaration.new(name: "parent", integration: :luarocks, group: :test),
    ]
    resolver = Dev::Deps::Resolver.new(repositories: { luarocks: repo })

    When "resolving"
    resolver.resolve(declarations)

    Then "child was fetched with parent's :test group"
    child_id = repo.fetched_ids.find { |id| id["name"] == "child" }
    child_id["group"] == "test"
  end

  test "normalizes string constraints on transitive deps to Hash" do
    Given "a parent whose transitive dep has a string constraint"
    child = Dev::Deps::Dependency.new(name: "child", integration: :luarocks, group: :app,
                                      version: "2.0", hash: "SHA256=bbb", metadata: {})
    parent = Dev::Deps::Dependency.new(name: "parent", integration: :luarocks, group: :app,
                                       version: "1.0", hash: "SHA256=aaa", metadata: {},
                                       dependencies: [{ name: "child", constraint: ">= 2.0" }])
    repo = StubRepository.new(deps_by_name: { "parent" => parent, "child" => child })
    declarations = [
      Dev::Deps::DependencyDeclaration.new(name: "parent", integration: :luarocks, group: :app),
    ]
    resolver = Dev::Deps::Resolver.new(repositories: { luarocks: repo })

    When "resolving"
    resolver.resolve(declarations)

    Then "string constraint was normalized to a version hash"
    child_id = repo.fetched_ids.find { |id| id["name"] == "child" }
    child_id["version"] == ">= 2.0"
  end

  test "unions platforms across groups and resolves a duplicated dep once" do
    Given "SML declared in :app (no platform) and :integration (LinuxServer)"
    sml = Dev::Deps::Dependency.new(name: "SML", integration: :ficsit, group: :app,
                                    version: "3.12.0", hash: nil, metadata: {})
    repo = StubRepository.new(deps_by_name: { "SML" => sml })
    declarations = [
      Dev::Deps::DependencyDeclaration.new(name: "SML", integration: :ficsit, group: :app),
      Dev::Deps::DependencyDeclaration.new(name: "SML", integration: :ficsit, group: :integration,
                                           platform: "LinuxServer"),
    ]
    resolver = Dev::Deps::Resolver.new(repositories: { ficsit: repo })

    When "resolving"
    result = resolver.resolve(declarations)

    Then "fetched once, with the union of both groups' platforms"
    result.size == 1
    repo.fetched_ids.size == 1
    repo.fetched_ids[0]["platforms"].sort_by(&:to_s) == [nil, "LinuxServer"].sort_by(&:to_s)
  end

  test "omits platforms from the fetch id when no group pins a platform" do
    Given "a dep declared only in groups without a platform"
    boost = Dev::Deps::Dependency.new(name: "boost", integration: :cmake, group: :app,
                                      version: "1.0", hash: nil, metadata: {})
    repo = StubRepository.new(deps_by_name: { "boost" => boost })
    declarations = [
      Dev::Deps::DependencyDeclaration.new(name: "boost", integration: :cmake, group: :app),
    ]
    resolver = Dev::Deps::Resolver.new(repositories: { cmake: repo })

    When "resolving"
    resolver.resolve(declarations)

    Then "no platforms key leaks into the fetch id"
    !repo.fetched_ids[0].key?("platforms")
  end

  test "carries post_install from declaration to resolved dependency" do
    Given "a declaration with a post_install hook"
    hook = ->(dep, root) {}
    dep = Dev::Deps::Dependency.new(name: "gtest", integration: :cmake, group: :test,
                                    version: "sha1", hash: nil, metadata: {})
    repo = StubRepository.new(deps_by_name: { "gtest" => dep })
    declarations = [
      Dev::Deps::DependencyDeclaration.new(name: "gtest", integration: :cmake, group: :test,
                                            post_install: hook),
    ]
    resolver = Dev::Deps::Resolver.new(repositories: { cmake: repo })

    When "resolving"
    result = resolver.resolve(declarations)

    Then
    result[0].post_install == hook
  end

  test "post_install is nil when declaration has none" do
    Given "a declaration without post_install"
    dep = Dev::Deps::Dependency.new(name: "boost", integration: :cmake, group: :app,
                                    version: "sha1", hash: nil, metadata: {})
    repo = StubRepository.new(deps_by_name: { "boost" => dep })
    declarations = [
      Dev::Deps::DependencyDeclaration.new(name: "boost", integration: :cmake, group: :app),
    ]
    resolver = Dev::Deps::Resolver.new(repositories: { cmake: repo })

    When "resolving"
    result = resolver.resolve(declarations)

    Then
    result[0].post_install.nil?
  end
end

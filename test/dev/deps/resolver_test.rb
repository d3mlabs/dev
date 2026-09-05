# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/resolver"
require "dev/deps/repository"
require "dev/deps/package"
require "dev/deps/package_id"
require "dev/deps/package_version"
require "dev/deps/dependency_edge"
require "dev/deps/dependency_declaration"
require "dev/deps/pinned_scheme"
require "dev/deps/semver_scheme"

# Stub repository over a canned universe: name -> [PackageVersion, ...].
# Records every find call (id + filter) for assertion.
class StubRepository < Dev::Deps::Repository
  attr_reader :finds

  def initialize(universes: {})
    @universes = universes
    @finds = []
  end

  def find(id, filter: {})
    @finds << { id: id, filter: filter }
    versions = @universes.fetch(id.name) do
      raise Dev::Deps::Repository::PackageNotFoundError, "no package #{id.name}"
    end
    Dev::Deps::Package.new(id: id, versions: versions)
  end
end

transform!(RSpock::AST::Transformation)
class Dev::Deps::ResolverTest < Minitest::Test
  # Shorthand: a PackageVersion universe entry.
  def version(v, digest: nil, platforms: [], dependencies: [], metadata: {})
    Dev::Deps::PackageVersion.new(
      version: v, digest: digest, platforms: platforms,
      dependencies: dependencies, metadata: metadata,
    )
  end

  def edge(name, constraint)
    Dev::Deps::DependencyEdge.new(name: name, constraint: constraint)
  end

  def declaration(**kwargs)
    Dev::Deps::DependencyDeclaration.new(**kwargs)
  end

  def resolver_for(integration, repo, scheme: Dev::Deps::PinnedScheme.new)
    Dev::Deps::Resolver.new(repositories: { integration => repo }, schemes: { integration => scheme })
  end

  test "mints a pin per declaration from each package's facts" do
    Given "two independent single-version universes"
    repo = StubRepository.new(universes: {
      "boost" => [version("sha1")],
      "gtest" => [version("sha2", digest: "SHA256=abc")],
    })
    declarations = [
      declaration(name: "boost", integration: :cmake, group: :app),
      declaration(name: "gtest", integration: :cmake, group: :test),
    ]

    When "resolving"
    result = resolver_for(:cmake, repo).resolve(declarations)

    Then "each pin carries the version's facts and the declaration's axes"
    result.map(&:name).sort == ["boost", "gtest"]
    result.find { |d| d.name == "boost" }.version == "sha1"
    boost = result.find { |d| d.name == "boost" }
    boost.integration == :cmake
    boost.group == :app
    result.find { |d| d.name == "gtest" }.hash == "SHA256=abc"
  end

  test "picks the highest satisfying version per the integration's scheme" do
    Given "a multi-version universe and a semver range"
    repo = StubRepository.new(universes: {
      "SML" => [version("3.12.0"), version("3.13.1"), version("4.0.0")],
    })
    declarations = [
      declaration(name: "SML", integration: :ficsit, group: :app, constraint: { "version" => "^3.12.0" }),
    ]

    When "resolving with SemverScheme"
    result = resolver_for(:ficsit, repo, scheme: Dev::Deps::SemverScheme.new).resolve(declarations)

    Then "the highest in-range version wins — not the highest overall"
    result[0].version == "3.13.1"
  end

  test "skips universe versions the scheme cannot parse instead of failing" do
    Given "a universe polluted with a non-semver tag"
    repo = StubRepository.new(universes: {
      "SML" => [version("not-a-version"), version("3.12.0")],
    })
    declarations = [
      declaration(name: "SML", integration: :ficsit, group: :app, constraint: { "version" => "^3.0.0" }),
    ]

    When "resolving with SemverScheme"
    result = resolver_for(:ficsit, repo, scheme: Dev::Deps::SemverScheme.new).resolve(declarations)

    Then "the unparseable candidate is simply not a candidate"
    result[0].version == "3.12.0"
  end

  test "raises NoSatisfyingVersionError when nothing in the universe qualifies" do
    Given "a universe entirely below the constraint"
    repo = StubRepository.new(universes: { "SML" => [version("2.0.0")] })
    declarations = [
      declaration(name: "SML", integration: :ficsit, group: :app, constraint: { "version" => "^3.0.0" }),
    ]

    When "resolving"
    resolver_for(:ficsit, repo, scheme: Dev::Deps::SemverScheme.new).resolve(declarations)

    Then
    raises Dev::Deps::Resolver::NoSatisfyingVersionError
  end

  test "raises ConflictingDeclarationError when one name carries two constraints" do
    Given "the same dep declared with disagreeing constraints"
    repo = StubRepository.new(universes: { "SML" => [version("3.12.0")] })
    declarations = [
      declaration(name: "SML", integration: :ficsit, group: :app, constraint: { "version" => "^3.0.0" }),
      declaration(name: "SML", integration: :ficsit, group: :test, constraint: { "version" => "^2.0.0" }),
    ]

    When "resolving"
    resolver_for(:ficsit, repo).resolve(declarations)

    Then
    raises Dev::Deps::Resolver::ConflictingDeclarationError
  end

  test "resolves the same name declared under two integrations independently" do
    Given "ffi declared under both bundler and brew"
    bundler_repo = StubRepository.new(universes: { "ffi" => [version("1.17.0")] })
    brew_repo = StubRepository.new(universes: { "ffi" => [version("3.4.0")] })
    resolver = Dev::Deps::Resolver.new(
      repositories: { bundler: bundler_repo, brew: brew_repo },
      schemes: { bundler: Dev::Deps::PinnedScheme.new, brew: Dev::Deps::PinnedScheme.new },
    )
    declarations = [
      declaration(name: "ffi", integration: :bundler, group: :app),
      declaration(name: "ffi", integration: :brew, group: :app),
    ]

    When "resolving"
    result = resolver.resolve(declarations)

    Then "both resolve, each in its own integration's universe"
    result.size == 2
    result.map { |d| [d.integration, d.version] }.sort == [[:brew, "3.4.0"], [:bundler, "1.17.0"]].sort
  end

  test "same name under two integrations with different constraints is not a conflict" do
    Given "each integration constrains its own ffi differently"
    bundler_repo = StubRepository.new(universes: { "ffi" => [version("1.17.0")] })
    brew_repo = StubRepository.new(universes: { "ffi" => [version("3.4.0")] })
    resolver = Dev::Deps::Resolver.new(
      repositories: { bundler: bundler_repo, brew: brew_repo },
      schemes: { bundler: Dev::Deps::SemverScheme.new, brew: Dev::Deps::SemverScheme.new },
    )
    declarations = [
      declaration(name: "ffi", integration: :bundler, group: :app, constraint: { "version" => "^1.0.0" }),
      declaration(name: "ffi", integration: :brew, group: :app, constraint: { "version" => "^3.0.0" }),
    ]

    When "resolving"
    result = resolver.resolve(declarations)

    Then "no ConflictingDeclarationError — constraints are scoped per integration"
    result.size == 2
  end

  test "transitive edge resolves within its own integration's namespace" do
    Given "a ficsit mod with an edge to zlib, and brew's zlib also declared"
    ficsit_repo = StubRepository.new(universes: {
      "SML" => [version("3.12.0", dependencies: [edge("zlib", nil)])],
      "zlib" => [version("1.3.1")],
    })
    brew_repo = StubRepository.new(universes: { "zlib" => [version("1.2.0")] })
    resolver = Dev::Deps::Resolver.new(
      repositories: { ficsit: ficsit_repo, brew: brew_repo },
      schemes: { ficsit: Dev::Deps::SemverScheme.new, brew: Dev::Deps::PinnedScheme.new },
    )
    declarations = [
      declaration(name: "zlib", integration: :brew, group: :app),
      declaration(name: "SML", integration: :ficsit, group: :app),
    ]

    When "resolving"
    result = resolver.resolve(declarations)

    Then "zlib resolved twice, once per integration, from each one's universe"
    result.size == 3
    zlibs = result.select { |d| d.name == "zlib" }
    zlibs.map(&:integration).sort == [:brew, :ficsit]
    zlibs.find { |d| d.integration == :ficsit }.version == "1.3.1"
    zlibs.find { |d| d.integration == :brew }.version == "1.2.0"
  end

  test "raises UnknownIntegrationError for unregistered integration" do
    Given "a declaration referencing an unregistered integration"
    resolver = Dev::Deps::Resolver.new(repositories: {}, schemes: {})
    declarations = [declaration(name: "foo", integration: :unknown, group: :app)]

    When "resolving"
    resolver.resolve(declarations)

    Then
    raises Dev::Deps::Resolver::UnknownIntegrationError
  end

  test "passes the declaration constraint to find as the locator filter" do
    Given "a pinned-identity declaration (gh-style)"
    repo = StubRepository.new(universes: { "engine" => [version("5.8.0")] })
    declarations = [
      declaration(name: "engine", integration: :gh, group: :editor,
        constraint: { "repo" => "d3mlabs/unreal-engine", "tag" => "5.8.0" }),
    ]

    When "resolving"
    resolver_for(:gh, repo).resolve(declarations)

    Then "the constraint rode along as the filter, and repo/url became the id's source"
    repo.finds[0][:filter]["tag"] == "5.8.0"
    repo.finds[0][:id].source == "d3mlabs/unreal-engine"
    repo.finds[0][:id].name == "engine"
    repo.finds[0][:id].integration == :gh
  end

  test "attaches host and env from the declaration onto minted metadata" do
    Given "declarations carrying the install-scoping axes"
    repo = StubRepository.new(universes: {
      "UnrealEngineMac" => [version("5.8.0", metadata: { "repo" => "d3mlabs/unreal-engine" })],
      "ruby" => [version("4.0")],
    })
    declarations = [
      declaration(name: "UnrealEngineMac", integration: :gh, group: :editor, host: :darwin),
      declaration(name: "ruby", integration: :gh, group: :build, env: "ci"),
    ]

    When "resolving"
    result = resolver_for(:gh, repo).resolve(declarations)

    Then "host/env land in metadata, existing metadata intact, axes never reach find"
    mac = result.find { |d| d.name == "UnrealEngineMac" }
    mac.metadata["host"] == "darwin"
    mac.metadata["repo"] == "d3mlabs/unreal-engine"
    result.find { |d| d.name == "ruby" }.metadata["env"] == "ci"
    repo.finds.none? { |call| call[:filter].key?("host") || call[:filter].key?("env") }
  end

  test "walks transitive edges, inheriting group, host, and env" do
    Given "a scoped parent whose chosen version has an edge"
    repo = StubRepository.new(universes: {
      "parent" => [version("1.0.0", dependencies: [edge("child", "^2.0.0")])],
      "child" => [version("2.0.0"), version("3.0.0")],
    })
    declarations = [
      declaration(name: "parent", integration: :ficsit, group: :test, host: :darwin, env: "ci"),
    ]

    When "resolving"
    result = resolver_for(:ficsit, repo, scheme: Dev::Deps::SemverScheme.new).resolve(declarations)

    Then "the child resolved under the edge constraint with the parent's scoping"
    child = result.find { |d| d.name == "child" }
    child.version == "2.0.0"
    child.group == :test
    child.metadata["host"] == "darwin"
    child.metadata["env"] == "ci"
  end

  test "resolves deep transitive chains and terminates on cycles" do
    Given "a depends on b, b depends on c, c depends back on a"
    repo = StubRepository.new(universes: {
      "a" => [version("1.0.0", dependencies: [edge("b", nil)])],
      "b" => [version("2.0.0", dependencies: [edge("c", nil)])],
      "c" => [version("3.0.0", dependencies: [edge("a", nil)])],
    })
    declarations = [declaration(name: "a", integration: :ficsit, group: :app)]

    When "resolving"
    result = resolver_for(:ficsit, repo, scheme: Dev::Deps::SemverScheme.new).resolve(declarations)

    Then "each package resolved exactly once"
    result.map(&:name).sort == ["a", "b", "c"]
    repo.finds.size == 3
  end

  test "resolves diamond dependencies without duplication" do
    Given "a depends on b and c, both depend on d"
    repo = StubRepository.new(universes: {
      "a" => [version("1.0.0", dependencies: [edge("b", nil), edge("c", nil)])],
      "b" => [version("1.0.0", dependencies: [edge("d", nil)])],
      "c" => [version("1.0.0", dependencies: [edge("d", nil)])],
      "d" => [version("1.0.0")],
    })
    declarations = [declaration(name: "a", integration: :ficsit, group: :app)]

    When "resolving"
    result = resolver_for(:ficsit, repo, scheme: Dev::Deps::SemverScheme.new).resolve(declarations)

    Then
    result.size == 4
    result.map(&:name).sort == ["a", "b", "c", "d"]
  end

  test "does not duplicate deps declared directly and reachable transitively" do
    Given "overlapping direct and transitive deps"
    repo = StubRepository.new(universes: {
      "a" => [version("1.0.0", dependencies: [edge("b", nil)])],
      "b" => [version("1.0.0")],
    })
    declarations = [
      declaration(name: "a", integration: :ficsit, group: :app),
      declaration(name: "b", integration: :ficsit, group: :app),
    ]

    When "resolving"
    result = resolver_for(:ficsit, repo, scheme: Dev::Deps::SemverScheme.new).resolve(declarations)

    Then
    result.size == 2
  end

  test "unions platforms across groups and resolves a duplicated dep once" do
    Given "SML declared in :app (no platform) and :integration (LinuxServer)"
    repo = StubRepository.new(universes: {
      "SML" => [version("3.12.0", platforms: ["Windows", "LinuxServer"])],
    })
    declarations = [
      declaration(name: "SML", integration: :ficsit, group: :app),
      declaration(name: "SML", integration: :ficsit, group: :integration, platform: "LinuxServer"),
    ]

    When "resolving"
    result = resolver_for(:ficsit, repo).resolve(declarations)

    Then "found once, with the union of both groups' platforms in the filter"
    result.size == 1
    repo.finds.size == 1
    repo.finds[0][:filter]["platforms"].sort_by(&:to_s) == [nil, "LinuxServer"].sort_by(&:to_s)
  end

  test "rejects versions that do not publish an explicitly requested platform" do
    Given "the latest version dropped the requested platform"
    repo = StubRepository.new(universes: {
      "SML" => [
        version("3.12.0", platforms: ["Windows", "LinuxServer"]),
        version("3.13.0", platforms: ["Windows"]),
      ],
    })
    declarations = [
      declaration(name: "SML", integration: :ficsit, group: :app, platform: "LinuxServer",
        constraint: { "version" => "^3.0.0" }),
    ]

    When "resolving"
    result = resolver_for(:ficsit, repo, scheme: Dev::Deps::SemverScheme.new).resolve(declarations)

    Then "the older version that still publishes the platform wins"
    result[0].version == "3.12.0"
  end

  test "omits platforms from the filter when no group pins a platform" do
    Given "a dep declared only in groups without a platform"
    repo = StubRepository.new(universes: { "boost" => [version("1.0")] })
    declarations = [declaration(name: "boost", integration: :cmake, group: :app)]

    When "resolving"
    resolver_for(:cmake, repo).resolve(declarations)

    Then "no platforms key leaks into the filter"
    !repo.finds[0][:filter].key?("platforms")
  end

  test "an empty chosen version string becomes a nil pin version" do
    Given "a versionless universe (brew cask style)"
    repo = StubRepository.new(universes: { "docker" => [version("", metadata: { "cask" => true })] })
    declarations = [declaration(name: "docker", integration: :brew, group: :app)]

    When "resolving"
    result = resolver_for(:brew, repo).resolve(declarations)

    Then
    result[0].version.nil?
    result[0].metadata["cask"] == true
  end

  test "carries post_install from declaration to resolved dependency" do
    Given "a declaration with a post_install hook"
    hook = ->(dep, root) {}
    repo = StubRepository.new(universes: { "gtest" => [version("sha1")] })
    declarations = [
      declaration(name: "gtest", integration: :cmake, group: :test, post_install: hook),
    ]

    When "resolving"
    result = resolver_for(:cmake, repo).resolve(declarations)

    Then
    result[0].post_install == hook
  end

  test "post_install is nil when declaration has none" do
    Given "a declaration without post_install"
    repo = StubRepository.new(universes: { "boost" => [version("sha1")] })
    declarations = [declaration(name: "boost", integration: :cmake, group: :app)]

    When "resolving"
    result = resolver_for(:cmake, repo).resolve(declarations)

    Then
    result[0].post_install.nil?
  end

  test "lets PackageNotFoundError from the repository propagate" do
    Given "a declaration nothing in the universe answers"
    repo = StubRepository.new(universes: {})
    declarations = [declaration(name: "ghost", integration: :cmake, group: :app)]

    When "resolving"
    resolver_for(:cmake, repo).resolve(declarations)

    Then
    raises Dev::Deps::Repository::PackageNotFoundError
  end
end

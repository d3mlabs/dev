# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/cmake_integration"
require "dev/deps/git_repository"
require "dev/deps/url_repository"
require "dev/deps/resolver"
require "dev/deps/declaration"
require "dev/deps/scope"
require "dev/deps/scoped_declaration"
require "dev/deps/local_store"
require "dev/deps/dependency"
require "dev/deps/package"
require "dev/deps/package_version"
require "dev/deps/git_scheme"
require "pathname"
require "tmpdir"

# Stub repository for end-to-end resolver tests: name -> [PackageVersion, ...].
class StubRepository < Dev::Deps::Repository
  def initialize(universes: {})
    @universes = universes
  end

  def find(id)
    Dev::Deps::Package.new(id: id, versions: @universes.fetch(id.name))
  end
end unless defined?(StubRepository)

# CmakeIntegration with the git boundary replaced by writing a checkout
# fixture where the clone would land (or failing the clone, for the names
# in fail_names). Publication, the marker, the link and the batch artifacts
# all run for real against the filesystem.
class FixtureCmakeIntegration < Dev::Deps::CmakeIntegration
  attr_reader :fetch_count

  def initialize(fail_names: [], **kwargs)
    super(**kwargs)
    @fail_names = fail_names
    @fetch_count = 0
  end

  private

  def fetch_git(dep, dest)
    @fetch_count += 1
    raise GitCloneError, "git clone #{dep.metadata["repo"]} failed" if @fail_names.include?(dep.name)

    dest.mkpath
    (dest / "CMakeLists.txt").write("# #{dep.name} at #{dep.version}")
  end
end unless defined?(FixtureCmakeIntegration)

transform!(RSpock::AST::Transformation)
class Dev::Deps::CmakeIntegrationTest < Minitest::Test
  def prepopulate_dep(root, name)
    dep_src = File.join(root, "build", "_deps", "#{name}-src")
    FileUtils.mkdir_p(dep_src)
    File.write(File.join(dep_src, "CMakeLists.txt"), "cmake_minimum_required(VERSION 3.20)")
  end

  HIGHWAY_SHA = "457c891775a7397bdb0376bb1031e6e027af1c48"

  def git_dependency(name: "highway", repo: "https://github.com/google/highway", version: HIGHWAY_SHA)
    Dev::Deps::Dependency.new(
      name: name, integration: :cmake, group: :app,
      version: version, hash: nil, metadata: { "repo" => repo },
    )
  end

  def url_dependency(hash: "SHA256=deadbeef", url: "https://example.com/boost-1.90.0.tar.gz")
    Dev::Deps::Dependency.new(
      name: "boost", integration: :url, group: :app,
      version: "1.90.0", hash: hash, metadata: { "url" => url },
    )
  end

  # A store and a fixture integration for a checkout at `root`, over `data_root`.
  def fixture_integration(root, data_root, fail_names: [])
    FixtureCmakeIntegration.new(
      fail_names: fail_names,
      repository: Dev::Deps::GitRepository.new,
      store: Dev::Deps::LocalStore.new(data_root: data_root),
      project_root: root,
    )
  end

  # Where the store publishes a git source under `data_root`.
  def published_source(data_root, sha: HIGHWAY_SHA)
    Pathname(data_root) / "cmake" / "github.com" / "google" / "highway" / sha
  end

  def source_link(root, name)
    Pathname(root) / "build" / "_deps" / "#{name}-src"
  end

  # A real .tar.gz with one top-level directory, as upstream tarballs ship.
  def build_tarball(dir)
    content = File.join(dir, "boost-1.90.0")
    FileUtils.mkdir_p(content)
    File.write(File.join(content, "CMakeLists.txt"), "# boost")
    tarball = File.join(dir, "boost.tar.gz")
    system("tar", "czf", tarball, "-C", dir, "boost-1.90.0") || raise("fixture build failed")
    tarball
  end

  test "tree_key places a git source by identity: ~/.dev/cmake/<host>/<path>/<sha>" do
    Given "a locked git cmake dep"
    dep = git_dependency

    When "asking where its source lives"
    key = Dev::Deps::CmakeIntegration.tree_key(dep)

    Then "the base is the remote under the cmake root, the version the pinned sha, the marker cmake's"
    [key.base, key.version, key.marker, key.platform] ==
      ["~/.dev/cmake/github.com/google/highway", HIGHWAY_SHA, Dev::Deps::CmakeIntegration::MARKER_FILE, nil]
  end

  test "tree_key names one tree for the spellings of a remote: #{repo}" do
    Expect "scheme, login, scp-style colon and .git suffix fall away"
    Dev::Deps::CmakeIntegration.tree_key(git_dependency(repo: repo)).base == "~/.dev/cmake/github.com/google/highway"

    Where
    repo                                       | _
    "https://github.com/google/highway"        | nil
    "https://github.com/google/highway.git"    | nil
    "https://github.com/google/highway/"       | nil
    "git@github.com:google/highway.git"        | nil
    "ssh://git@github.com/google/highway.git"  | nil
  end

  test "tree_key places a url source by identity and digest: ~/.dev/cmake/<host>/<path>/<digest>" do
    Given "a locked url dep whose pin version is a display label"
    dep = url_dependency(hash: "SHA256=deadbeef")

    When "asking where its source lives"
    key = Dev::Deps::CmakeIntegration.tree_key(dep)

    Then "the base is the download URL under the cmake root and the version the locked digest, not the label"
    [key.base, key.version] == ["~/.dev/cmake/example.com/boost-1.90.0.tar.gz", "SHA256=deadbeef"]
  end

  test "tree_key raises MissingDigestError for a url pin locked without a digest" do
    Given "a url dep with no hash"
    dep = url_dependency(hash: nil)

    When "asking where its source lives"
    error = assert_raises(Dev::Deps::CmakeIntegration::MissingDigestError) do
      Dev::Deps::CmakeIntegration.tree_key(dep)
    end

    Then "the remediation is a re-lock"
    error.message.include?("dev deps update")
  end

  test "install_all publishes a git source to the store once and links build/_deps/<name>-src at it" do
    Given "a checkout, an empty data root and a git dep"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    root = File.join(dir, "checkout")
    data_root = File.join(dir, "data")
    integration = fixture_integration(root, data_root)
    deps = [git_dependency]

    When "installing"
    integration.install_all(deps)
    link = source_link(root, "highway")

    Then "the source is a marker-stamped tree in the store and the checkout path is a link to it"
    integration.fetch_count == 1
    (published_source(data_root) / "CMakeLists.txt").read == "# highway at #{HIGHWAY_SHA}"
    (published_source(data_root) / Dev::Deps::CmakeIntegration::MARKER_FILE).read == HIGHWAY_SHA
    link.symlink?
    link.readlink == published_source(data_root)
    (link / "CMakeLists.txt").file?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a second install over a warm store is a stat: the link is re-created from the store, nothing is fetched" do
    Given "a published source whose checkout link a clean wiped"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    root = File.join(dir, "checkout")
    data_root = File.join(dir, "data")
    fixture_integration(root, data_root).install_all([git_dependency])
    FileUtils.rm_rf(File.join(root, "build"))
    integration = fixture_integration(root, data_root)

    When "installing again"
    integration.install_all([git_dependency])

    Then "no fetch, and the link points at the published tree again"
    integration.fetch_count == 0
    source_link(root, "highway").readlink == published_source(data_root)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "two worktrees of one project share the published source" do
    Given "two checkouts over one data root"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    data_root = File.join(dir, "data")
    first = fixture_integration(File.join(dir, "worktree-a"), data_root)
    second = fixture_integration(File.join(dir, "worktree-b"), data_root)

    When "each installs the same lock"
    first.install_all([git_dependency])
    second.install_all([git_dependency])

    Then "one fetch between them, both links at the one tree"
    [first.fetch_count, second.fetch_count] == [1, 0]
    source_link(File.join(dir, "worktree-a"), "highway").readlink == published_source(data_root)
    source_link(File.join(dir, "worktree-b"), "highway").readlink == published_source(data_root)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a lock that moves to another sha publishes beside the old tree and re-points the link" do
    Given "a checkout linked at one sha, and the lock at another"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    root = File.join(dir, "checkout")
    data_root = File.join(dir, "data")
    fixture_integration(root, data_root).install_all([git_dependency])
    integration = fixture_integration(root, data_root)
    moved = git_dependency(version: "0" * 40)

    When "installing the moved lock"
    integration.install_all([moved])

    Then "the new sha is published, the old tree stands, the link follows the lock"
    integration.fetch_count == 1
    published_source(data_root, sha: "0" * 40).directory?
    published_source(data_root).directory?
    source_link(root, "highway").readlink == published_source(data_root, sha: "0" * 40)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a pre-existing plain build/_deps/<name>-src is kept: nothing is fetched or published" do
    Given "a checkout whose build/_deps holds a populated plain directory from before"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    root = File.join(dir, "checkout")
    data_root = File.join(dir, "data")
    prepopulate_dep(root, "highway")
    integration = fixture_integration(root, data_root)
    link = source_link(root, "highway")

    When "installing"
    integration.install_all([git_dependency])

    Then "the directory is untouched and the store has no tree for it"
    integration.fetch_count == 0
    !link.symlink?
    (link / "CMakeLists.txt").read == "cmake_minimum_required(VERSION 3.20)"
    !published_source(data_root).exist?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all publishes a url source from the store's cached tarball, keyed by its digest" do
    Given "a url dep whose tarball is already a blob in the store"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    root = File.join(dir, "checkout")
    data_root = File.join(dir, "data")
    store = Dev::Deps::LocalStore.new(data_root: data_root)
    dep = url_dependency(hash: "SHA256=cafef00d")
    store.put_blob(dep.hash, File.open(build_tarball(File.join(dir, "fixture"))))
    integration = Dev::Deps::CmakeIntegration.new(repository: Dev::Deps::UrlRepository.new, store: store, project_root: root)
    published = Pathname(data_root) / "cmake" / "example.com" / "boost-1.90.0.tar.gz" / "SHA256=cafef00d"

    When "installing"
    integration.install_all([dep])

    Then "the extracted top-level directory is the published tree and the link reads it"
    (published / "CMakeLists.txt").read == "# boost"
    (published / Dev::Deps::CmakeIntegration::MARKER_FILE).read == "SHA256=cafef00d"
    (source_link(root, "boost") / "CMakeLists.txt").file?
    File.read(File.join(root, "deps.cmake")).include?('set(dep_boost_hash "SHA256=cafef00d")')

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all generates deps.cmake with repo+sha entries" do
    Given "a git-backed cmake dependency"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    store = Dev::Deps::LocalStore.new(data_root: dir)
    git_repo = Dev::Deps::GitRepository.new
    integration = Dev::Deps::CmakeIntegration.new(repository: git_repo, store: store, project_root: dir)
    prepopulate_dep(dir, "cereal")
    deps = [
      Dev::Deps::Dependency.new(
        name: "cereal", integration: :cmake, group: :app,
        version: "abc123def456", hash: nil,
        metadata: { "repo" => "https://github.com/USCiLab/cereal" },
      ),
    ]

    When "installing all"
    integration.install_all(deps)
    cmake_content = File.read(File.join(dir, "deps.cmake"))

    Then "the entries land under a header naming the verb that regenerates the file"
    cmake_content.include?("run dev deps update to change")
    cmake_content.include?('set(dep_cereal_repo "https://github.com/USCiLab/cereal")')
    cmake_content.include?('set(dep_cereal_sha "abc123def456")')

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all generates deps.cmake with url+hash entries" do
    Given "a URL-backed cmake dependency"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    store = Dev::Deps::LocalStore.new(data_root: dir)
    url_repo = Dev::Deps::UrlRepository.new
    integration = Dev::Deps::CmakeIntegration.new(repository: url_repo, store: store, project_root: dir)
    prepopulate_dep(dir, "boost")
    deps = [
      Dev::Deps::Dependency.new(
        name: "boost", integration: :cmake, group: :app,
        version: "1.90.0", hash: "SHA256=deadbeef",
        metadata: { "url" => "https://example.com/boost.tar.gz" },
      ),
    ]

    When "installing all"
    integration.install_all(deps)
    cmake_content = File.read(File.join(dir, "deps.cmake"))

    Then
    cmake_content.include?('set(dep_boost_url "https://example.com/boost.tar.gz")')
    cmake_content.include?('set(dep_boost_hash "SHA256=deadbeef")')

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all generates RUNTIME_DEPS_APP and RUNTIME_DEPS_TEST lists" do
    Given "app and test cmake dependencies"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    store = Dev::Deps::LocalStore.new(data_root: dir)
    git_repo = Dev::Deps::GitRepository.new
    integration = Dev::Deps::CmakeIntegration.new(repository: git_repo, store: store, project_root: dir)
    prepopulate_dep(dir, "boost")
    prepopulate_dep(dir, "gtest")
    deps = [
      Dev::Deps::Dependency.new(name: "boost", integration: :cmake, group: :app,
        version: "sha1", hash: nil,
        metadata: { "repo" => "https://github.com/boost/boost" }),
      Dev::Deps::Dependency.new(name: "gtest", integration: :cmake, group: :test,
        version: "sha2", hash: nil,
        metadata: { "repo" => "https://github.com/google/googletest" }),
    ]

    When "installing all"
    integration.install_all(deps)
    cmake_content = File.read(File.join(dir, "deps.cmake"))

    Then
    cmake_content.include?('set(RUNTIME_DEPS_APP "boost")')
    cmake_content.include?('set(RUNTIME_DEPS_TEST "gtest")')

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all raises GitCloneError when git clone fails" do
    Given "a git dep with no prepopulated source and a failing git clone"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    store = Dev::Deps::LocalStore.new(data_root: dir)
    git_repo = Dev::Deps::GitRepository.new
    integration = Dev::Deps::CmakeIntegration.new(repository: git_repo, store: store, project_root: dir)
    deps = [
      Dev::Deps::Dependency.new(
        name: "bad_repo", integration: :cmake, group: :app,
        version: "abc123", hash: nil,
        metadata: { "repo" => "https://example.com/bad_repo" },
      ),
    ]
    integration.stubs(:system).returns(false)

    When "installing all"
    error = assert_raises(Dev::Deps::Integration::PartialInstallError) do
      integration.install_all(deps)
    end

    Then "the per-dep failure is the clone error"
    error.failures[0][1].is_a?(Dev::Deps::CmakeIntegration::GitCloneError)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all raises GitCheckoutError when checkout fails" do
    Given "a git dep where clone succeeds but checkout fails"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    store = Dev::Deps::LocalStore.new(data_root: dir)
    git_repo = Dev::Deps::GitRepository.new
    integration = Dev::Deps::CmakeIntegration.new(repository: git_repo, store: store, project_root: dir)
    deps = [
      Dev::Deps::Dependency.new(
        name: "bad_checkout", integration: :cmake, group: :app,
        version: "abc123", hash: nil,
        metadata: { "repo" => "https://example.com/bad_checkout" },
      ),
    ]
    integration.stubs(:system)
               .with("git", "clone", "--no-checkout", "-q", anything, anything)
               .returns(true)
    integration.stubs(:system)
               .with("git", "-c", "advice.detachedHead=false", "checkout", anything, chdir: anything)
               .returns(false)

    When "installing all"
    error = assert_raises(Dev::Deps::Integration::PartialInstallError) do
      integration.install_all(deps)
    end

    Then "the per-dep failure is the checkout error"
    error.failures[0][1].is_a?(Dev::Deps::CmakeIntegration::GitCheckoutError)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all raises DownloadError when curl fails" do
    Given "a URL dep with no cache and a failing download"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    store = Dev::Deps::LocalStore.new(data_root: dir)
    url_repo = Dev::Deps::UrlRepository.new
    integration = Dev::Deps::CmakeIntegration.new(repository: url_repo, store: store, project_root: dir)
    deps = [
      Dev::Deps::Dependency.new(
        name: "bad_url", integration: :cmake, group: :app,
        version: "1.0.0", hash: "SHA256=feedface",
        metadata: { "url" => "https://example.com/missing.tar.gz" },
      ),
    ]
    integration.stubs(:system)
               .with("curl", "-fsSL", "-o", anything, anything)
               .returns(false)

    When "installing all"
    error = assert_raises(Dev::Deps::Integration::PartialInstallError) do
      integration.install_all(deps)
    end

    Then "the per-dep failure is the download error"
    error.failures[0][1].is_a?(Dev::Deps::CmakeIntegration::DownloadError)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all raises ExtractError when tar fails" do
    Given "a URL dep with a tarball that fails to extract"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    store = Dev::Deps::LocalStore.new(data_root: dir)
    url_repo = Dev::Deps::UrlRepository.new
    integration = Dev::Deps::CmakeIntegration.new(repository: url_repo, store: store, project_root: dir)
    deps = [
      Dev::Deps::Dependency.new(
        name: "bad_tar", integration: :cmake, group: :app,
        version: "1.0.0", hash: "SHA256=feedface",
        metadata: { "url" => "https://example.com/bad.tar.gz" },
      ),
    ]
    # curl succeeds but tar fails
    integration.stubs(:system).with { |cmd, *_| cmd == "curl" }.returns(true)
    integration.stubs(:system).with { |cmd, *_| cmd == "tar" }.returns(false)

    When "installing all"
    error = assert_raises(Dev::Deps::Integration::PartialInstallError) do
      integration.install_all(deps)
    end

    Then "the per-dep failure is the extract error"
    error.failures[0][1].is_a?(Dev::Deps::CmakeIntegration::ExtractError)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all generates deps.targets.cmake with cmake_targets" do
    Given "a dependency with cmake targets and namespace"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    store = Dev::Deps::LocalStore.new(data_root: dir)
    git_repo = Dev::Deps::GitRepository.new
    integration = Dev::Deps::CmakeIntegration.new(repository: git_repo, store: store, project_root: dir)
    prepopulate_dep(dir, "googletest")
    deps = [
      Dev::Deps::Dependency.new(
        name: "googletest", integration: :cmake, group: :test,
        version: "sha1", hash: nil,
        metadata: {
          "repo" => "https://github.com/google/googletest",
          "cmake_targets" => ["gtest", "gmock"],
          "cmake_namespace" => "GTest::",
        },
      ),
    ]

    When "installing all"
    integration.install_all(deps)
    targets_content = File.read(File.join(dir, "deps.targets.cmake"))

    Then
    targets_content.include?('set(dep_googletest_cmake_targets "gtest;gmock")')
    targets_content.include?('set(dep_googletest_cmake_namespace "GTest::")')

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all calls post_install hook after fetching" do
    Given "a dependency with a post_install hook"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    store = Dev::Deps::LocalStore.new(data_root: dir)
    git_repo = Dev::Deps::GitRepository.new
    integration = Dev::Deps::CmakeIntegration.new(repository: git_repo, store: store, project_root: dir)
    prepopulate_dep(dir, "mylib")
    hook_calls = []
    hook = ->(dep, root) { hook_calls << [dep.name, root.to_s] }
    deps = [
      Dev::Deps::Dependency.new(
        name: "mylib", integration: :cmake, group: :app,
        version: "sha1", hash: nil,
        metadata: { "repo" => "https://github.com/example/mylib" },
        post_install: hook,
      ),
    ]

    When "installing all"
    integration.install_all(deps)

    Then
    hook_calls.size == 1
    hook_calls[0][0] == "mylib"
    hook_calls[0][1] == dir

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all calls multiple post_install hooks in order" do
    Given "a dependency with an array of post_install hooks"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    store = Dev::Deps::LocalStore.new(data_root: dir)
    git_repo = Dev::Deps::GitRepository.new
    integration = Dev::Deps::CmakeIntegration.new(repository: git_repo, store: store, project_root: dir)
    prepopulate_dep(dir, "mylib")
    order = []
    hook_a = ->(_dep, _root) { order << :a }
    hook_b = ->(_dep, _root) { order << :b }
    deps = [
      Dev::Deps::Dependency.new(
        name: "mylib", integration: :cmake, group: :app,
        version: "sha1", hash: nil,
        metadata: { "repo" => "https://github.com/example/mylib" },
        post_install: [hook_a, hook_b],
      ),
    ]

    When "installing all"
    integration.install_all(deps)

    Then
    order == [:a, :b]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "post_install hook receives correct dep and root from full DSL-resolve-install pipeline" do
    Given "a DSL config with a post_install hook wired through the resolver"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    store = Dev::Deps::LocalStore.new(data_root: dir)
    git_repo = Dev::Deps::GitRepository.new
    integration = Dev::Deps::CmakeIntegration.new(repository: git_repo, store: store, project_root: dir)
    prepopulate_dep(dir, "googletest")

    hook_calls = []
    hook = ->(dep, root) { hook_calls << { name: dep.name, version: dep.version, root: root.to_s } }

    universe = Dev::Deps::PackageVersion.new(
      version: "sha1",
      metadata: { "repo" => "https://github.com/google/googletest" },
    )
    stub_repo = StubRepository.new(universes: { "googletest" => [universe] })
    resolver = Dev::Deps::Resolver.new(
      repositories: { cmake: stub_repo },
      schemes: { cmake: Dev::Deps::GitScheme.new },
    )
    declarations = [
      Dev::Deps::ScopedDeclaration.new(
        declaration: Dev::Deps::Declaration.new(
          name: "googletest", integration: :cmake,
          source: "https://github.com/google/googletest",
        ),
        scope: Dev::Deps::Scope.new(group: :test),
        post_install: hook,
      ),
    ]

    When "resolving and installing"
    resolved = resolver.resolve(declarations)
    integration.install_all(resolved)

    Then "the hook was called with the resolved dep and project root"
    hook_calls.size == 1
    hook_calls[0][:name] == "googletest"
    hook_calls[0][:version] == "sha1"
    hook_calls[0][:root] == dir

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all skips post_install when nil" do
    Given "a dependency without a post_install hook"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    store = Dev::Deps::LocalStore.new(data_root: dir)
    git_repo = Dev::Deps::GitRepository.new
    integration = Dev::Deps::CmakeIntegration.new(repository: git_repo, store: store, project_root: dir)
    prepopulate_dep(dir, "boost")
    deps = [
      Dev::Deps::Dependency.new(
        name: "boost", integration: :cmake, group: :app,
        version: "sha1", hash: nil,
        metadata: { "repo" => "https://github.com/boost/boost" },
      ),
    ]

    When "installing all"
    integration.install_all(deps)
    cmake_content = File.read(File.join(dir, "deps.cmake"))

    Then "no error, deps.cmake still generated"
    cmake_content.include?('set(dep_boost_repo')

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "populated? treats a url dep's non-empty extract dir as populated: #{expected}" do
    Given "a source dir without .git or CMakeLists.txt"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    integration = Dev::Deps::CmakeIntegration.new(
      repository: Dev::Deps::UrlRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir), project_root: dir,
    )
    dest = Pathname(dir) / "boost-src"
    FileUtils.mkdir_p(dest)
    File.write(dest / "README.md", "extracted") if has_children
    dep = Dev::Deps::Dependency.new(
      name: "boost", integration: :cmake, group: :app,
      version: "1.90.0", hash: nil, metadata: metadata,
    )

    Expect "only a url dep with extracted children counts"
    integration.send(:populated?, dest, dep) == expected

    Cleanup
    FileUtils.rm_rf(dir)

    Where
    metadata                                    | has_children | expected
    { "url" => "https://example.com/b.tar.gz" } | true         | true
    { "url" => "https://example.com/b.tar.gz" } | false        | false
    {}                                          | true         | false
  end

  test "install_all leaves batch artifacts untouched when any dep fails, still attempting the rest" do
    Given "two git deps (first fails to clone) and pre-existing batch artifacts"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    integration = fixture_integration(dir, dir, fail_names: ["bad_repo"])
    previous_deps_cmake = "# previous consistent deps.cmake\n"
    previous_targets_cmake = "# previous consistent deps.targets.cmake\n"
    File.write(File.join(dir, "deps.cmake"), previous_deps_cmake)
    File.write(File.join(dir, "deps.targets.cmake"), previous_targets_cmake)
    deps = [
      git_dependency(name: "bad_repo", repo: "https://example.com/bad_repo", version: "abc123"),
      git_dependency(name: "good_repo", repo: "https://example.com/good_repo", version: "def456"),
    ]

    When "installing all and capturing the aggregate error"
    error = nil
    begin
      integration.install_all(deps)
    rescue StandardError => e
      error = e
    end

    Then "good_repo was still fetched and published, artifacts are stale-but-consistent"
    error.is_a?(Dev::Deps::Integration::PartialInstallError)
    error.failures.map(&:first) == ["bad_repo"]
    integration.fetch_count == 2
    source_link(dir, "good_repo").symlink?
    File.read(File.join(dir, "deps.cmake")) == previous_deps_cmake
    File.read(File.join(dir, "deps.targets.cmake")) == previous_targets_cmake

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/lockfile"
require "dev/deps/dependency"
require "tmpdir"
require "yaml"

transform!(RSpock::AST::Transformation)
class Dev::Deps::LockfileTest < Minitest::Test
  test "lock and read round-trips dependencies through YAML" do
    Given "a lockfile with two app/test dependencies"
    dir = Dir.mktmpdir("dev-lockfile-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: dir)
    deps = [
      Dev::Deps::Dependency.new(
        name: "boost", integration: :cmake, group: :app,
        version: "1.90.0", hash: "SHA256=deadbeef",
        metadata: { "url" => "https://example.com/boost.tar.gz" },
      ),
      Dev::Deps::Dependency.new(
        name: "luaunit", integration: :luarocks, group: :test,
        version: "3.5-1", hash: "SHA256=abc123",
        metadata: {},
      ),
    ]

    When "locking and reading back"
    lockfile.lock(deps)
    read_deps = lockfile.read

    Then
    read_deps.size == 2
    read_deps[0].name == "boost"
    read_deps[0].integration == :cmake
    read_deps[0].group == :app
    read_deps[0].version == "1.90.0"
    read_deps[0].hash == "SHA256=deadbeef"
    read_deps[0].metadata == { "url" => "https://example.com/boost.tar.gz" }
    read_deps[1].name == "luaunit"
    read_deps[1].integration == :luarocks
    read_deps[1].group == :test

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a pin's needed_by provenance survives the round-trip, so the installer can order by it" do
    Given "the xcodes formula as the resolver mints it from xcode's own manifest"
    dir = Dir.mktmpdir("dev-lockfile-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: dir)
    dep = Dev::Deps::Dependency.new(
      name: "xcodes", integration: :brew, group: :editor, version: "1.6.2", hash: nil,
      metadata: { "host" => "darwin", Dev::Deps::Dependency::NEEDED_BY => ["xcode"] },
    )

    When "locking and reading back"
    lockfile.lock([dep])
    read_dep = lockfile.read.first

    Then
    read_dep.metadata[Dev::Deps::Dependency::NEEDED_BY] == ["xcode"]
    read_dep.group == :editor

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a wwise pin's install instructions survive the round-trip — none is named like a reserved lock attribute" do
    Given "a wwise dependency as the DSL and resolver mint it"
    dir = Dir.mktmpdir("dev-lockfile-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: dir)
    metadata = {
      "integration_version" => "2023.1.14.3555",
      "ue" => "5.6",
      "packages" => ["SDK"],
      "deployment_platforms" => ["Linux", ""],
    }
    dep = Dev::Deps::Dependency.new(
      name: "Wwise", integration: :wwise, group: :build, version: "2023.1.14.8770", hash: nil, metadata: metadata,
    )

    When "locking and reading back"
    lockfile.lock([dep])
    read_dep = lockfile.read.first

    Then "the install reads exactly what was declared"
    read_dep.integration == :wwise
    read_dep.version == "2023.1.14.8770"
    read_dep.metadata == metadata

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "lock records the manifest digest in the header and reads it back" do
    Given "a dependency and the digest of the manifest it came from"
    dir = Dir.mktmpdir("dev-lockfile-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: dir)
    deps = [
      Dev::Deps::Dependency.new(
        name: "boost", integration: :cmake, group: :app,
        version: "1.90.0", hash: "SHA256=deadbeef", metadata: {},
      ),
      Dev::Deps::Dependency.new(
        name: "cmake", integration: :brew, group: :build,
        version: "3.31", hash: "SHA256=abc", metadata: {},
      ),
    ]
    digest = "a" * 64

    When "locking with the digest"
    lockfile.lock(deps, manifest_digest: digest)

    Then "the lockfile carries it as a header comment, names the verb that rewrites it, and it reads back"
    File.read(File.join(dir, "deps.lock")).include?("# dependencies-digest: #{digest}")
    File.read(File.join(dir, "deps.lock")).include?("run dev deps update to change")
    lockfile.manifest_digest == digest
    # The YAML payload stays pure deps — the digest rides a comment.
    YAML.safe_load(File.read(File.join(dir, "deps.lock")))["cmake"].key?("boost")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "manifest_digest is nil for legacy lockfiles without the header" do
    Given "a lockfile written without a manifest digest"
    dir = Dir.mktmpdir("dev-lockfile-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: dir)
    lockfile.lock([
      Dev::Deps::Dependency.new(
        name: "boost", integration: :cmake, group: :app,
        version: "1.90.0", hash: nil, metadata: {},
      ),
    ])

    Expect "legacy locks report no digest (unknown, not stale)"
    lockfile.manifest_digest.nil?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "lock produces readable YAML with header comment" do
    Given "a single dependency"
    dir = Dir.mktmpdir("dev-lockfile-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: dir)
    deps = [
      Dev::Deps::Dependency.new(
        name: "boost", integration: :cmake, group: :app,
        version: "1.90.0", hash: "SHA256=deadbeef", metadata: {},
      ),
    ]

    When "locking"
    lockfile.lock(deps)
    content = File.read(File.join(dir, "deps.lock"))

    Then
    content.include?("Generated by dev")
    content.include?("Do not edit")
    content.include?("boost:")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "read returns empty array when no lockfiles exist" do
    Given "an empty directory"
    dir = Dir.mktmpdir("dev-lockfile-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: dir)

    When "reading"
    deps = lockfile.read

    Then
    deps == []

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "lock writes every group to the one deps.lock" do
    Given "dependencies in app, test, and build groups"
    dir = Dir.mktmpdir("dev-lockfile-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: dir)
    deps = [
      Dev::Deps::Dependency.new(name: "boost", integration: :cmake, group: :app,
        version: "1.90.0", hash: "SHA256=aaa", metadata: {}),
      Dev::Deps::Dependency.new(name: "luaunit", integration: :luarocks, group: :test,
        version: "3.5-1", hash: "SHA256=bbb", metadata: {}),
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build,
        version: "3.31.4", hash: "SHA256=ccc", metadata: {}),
    ]

    When "locking and reading back"
    lockfile.lock(deps)
    all_deps = lockfile.read

    Then "one file holds all three, under their integration sections"
    all_deps.size == 3
    File.exist?(File.join(dir, "deps.lock"))
    !File.exist?(File.join(dir, "build-deps.lock"))
    all_deps.map(&:name).sort == ["boost", "cmake", "luaunit"]
    YAML.safe_load(File.read(File.join(dir, "deps.lock")))["brew"]["cmake"]["group"] == "build"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "env scope is a per-pin attribute, whatever the group" do
    Given "a build dependency scoped to an env"
    dir = Dir.mktmpdir("dev-lockfile-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: dir)
    deps = [
      Dev::Deps::Dependency.new(name: "ccache", integration: :brew, group: :build,
        version: "4.10.2", hash: "SHA256=aaa", metadata: {}),
      Dev::Deps::Dependency.new(name: "powershell", integration: :brew, group: :build,
        version: "7.4.0", hash: "SHA256=ccc",
        metadata: { "env" => "ci", "tap" => "d3mlabs/d3mlabs" }),
    ]

    When "locking"
    lockfile.lock(deps)
    yaml = YAML.safe_load(File.read(File.join(dir, "deps.lock")), permitted_classes: [Symbol])

    Then "the pin sits in its integration section with env beside its other attrs; no env: top-level section"
    yaml["brew"]["powershell"]["env"] == "ci"
    yaml["brew"]["powershell"]["tap"] == "d3mlabs/d3mlabs"
    !yaml["brew"]["ccache"].key?("env")
    !yaml.key?("env")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "lock removes a retired build-deps.lock beside the deps.lock it writes" do
    Given "a checkout last locked by a dev that wrote two files"
    dir = Dir.mktmpdir("dev-lockfile-test-")
    File.write(File.join(dir, "build-deps.lock"), "brew:\n  cmake: { group: build, version: '3.31' }\n")
    lockfile = Dev::Deps::Lockfile.new(dir: dir)
    deps = [
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build,
        version: "3.31.4", hash: "SHA256=ccc", metadata: {}),
    ]

    When "re-locking"
    lockfile.lock(deps)

    Then "the retired file is gone and the pin is in deps.lock"
    !File.exist?(File.join(dir, "build-deps.lock"))
    lockfile.read.map(&:name) == ["cmake"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "read refuses a checkout that still carries build-deps.lock" do
    Given "a deps.lock beside a retired build-deps.lock"
    dir = Dir.mktmpdir("dev-lockfile-test-")
    File.write(File.join(dir, "deps.lock"), "cmake:\n  boost: { group: app, version: '1.90.0' }\n")
    File.write(File.join(dir, "build-deps.lock"), "brew:\n  cmake: { group: build, version: '3.31' }\n")
    lockfile = Dev::Deps::Lockfile.new(dir: dir)

    When "reading"
    lockfile.read

    Then "it is RetiredBuildLockError, naming the command that folds the file in"
    error = raises Dev::Deps::Lockfile::RetiredBuildLockError
    error.message.include?("build-deps.lock")
    error.message.include?("dev deps update")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "custom groups round-trip through deps.lock" do
    Given "dependencies with custom groups alongside standard ones"
    dir = Dir.mktmpdir("dev-lockfile-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: dir)
    deps = [
      Dev::Deps::Dependency.new(name: "boost", integration: :cmake, group: :app,
        version: "1.90.0", hash: "SHA256=aaa", metadata: {}),
      Dev::Deps::Dependency.new(name: "mock-server", integration: :custom, group: :staging,
        version: "2.0.0", hash: "SHA256=bbb", metadata: {}),
      Dev::Deps::Dependency.new(name: "load-gen", integration: :custom, group: :integration,
        version: "1.0.0", hash: "SHA256=ccc",
        metadata: { "url" => "https://example.com/load-gen.tar.gz" }),
    ]

    When "locking and reading back"
    lockfile.lock(deps)
    read_deps = lockfile.read

    Then
    read_deps.size == 3
    staging_dep = read_deps.find { |d| d.name == "mock-server" }
    integration_dep = read_deps.find { |d| d.name == "load-gen" }
    !staging_dep.nil?
    staging_dep.group == :staging
    staging_dep.version == "2.0.0"
    !integration_dep.nil?
    integration_dep.group == :integration
    integration_dep.metadata == { "url" => "https://example.com/load-gen.tar.gz" }
    !File.exist?(File.join(dir, "build-deps.lock"))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "read round-trips env-scoped pins" do
    Given "global and env-scoped build dependencies"
    dir = Dir.mktmpdir("dev-lockfile-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: dir)
    deps = [
      Dev::Deps::Dependency.new(name: "ccache", integration: :brew, group: :build,
        version: "4.10.2", hash: "SHA256=aaa", metadata: {}),
      Dev::Deps::Dependency.new(name: "ruby", integration: :brew, group: :build,
        version: "3.3.0", hash: "SHA256=bbb",
        metadata: { "env" => "ci" }),
    ]

    When "locking and reading back"
    lockfile.lock(deps)
    read_deps = lockfile.read

    Then
    read_deps.size == 2
    global_dep = read_deps.find { |d| d.name == "ccache" }
    env_dep = read_deps.find { |d| d.name == "ruby" }
    !global_dep.nil?
    !env_dep.nil?
    env_dep.metadata["env"] == "ci"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "locks the same name under two integrations into nested sections" do
    Given "zlib declared under both cmake and brew"
    dir = Dir.mktmpdir("dev-lockfile-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: dir)
    deps = [
      Dev::Deps::Dependency.new(name: "zlib", integration: :cmake, group: :app,
        version: "1.3.1", hash: "SHA256=aaa", metadata: {}),
      Dev::Deps::Dependency.new(name: "zlib", integration: :brew, group: :app,
        version: "1.3", hash: "SHA256=bbb", metadata: {}),
    ]

    When "locking and reading back"
    lockfile.lock(deps)
    yaml = YAML.safe_load(File.read(File.join(dir, "deps.lock")))
    read_deps = lockfile.read

    Then "each lives in its integration's section, no integration field in values"
    yaml["cmake"]["zlib"]["version"] == "1.3.1"
    yaml["brew"]["zlib"]["version"] == "1.3"
    !yaml["cmake"]["zlib"].key?("integration")
    read_deps.size == 2
    read_deps.map { |d| [d.integration, d.version] }.sort == [[:brew, "1.3"], [:cmake, "1.3.1"]].sort

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "reads legacy flat-format lockfiles" do
    # Migration shim: delete this test with the legacy read path once every
    # consumer repo's lockfiles have been rewritten by dev deps update (issue #146).
    Given "a lockfile in the pre-nested format, name-keyed with integration in the value"
    dir = Dir.mktmpdir("dev-lockfile-test-")
    File.write(File.join(dir, "deps.lock"), <<~YAML)
      boost:
        integration: cmake
        group: app
        version: 1.90.0
        hash: SHA256=deadbeef
      ccache:
        integration: brew
        group: build
        version: 4.10.2
        env: ci
    YAML
    lockfile = Dev::Deps::Lockfile.new(dir: dir)

    When "reading"
    deps = lockfile.read

    Then "all entries parse with their recorded integrations"
    deps.size == 2
    boost = deps.find { |d| d.name == "boost" }
    boost.integration == :cmake
    boost.version == "1.90.0"
    ccache = deps.find { |d| d.name == "ccache" }
    ccache.integration == :brew
    ccache.metadata["env"] == "ci"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "post_install is not serialized to lockfile" do
    Given "a dependency with a post_install hook"
    dir = Dir.mktmpdir("dev-lockfile-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: dir)
    hook = ->(dep, root) {}
    deps = [
      Dev::Deps::Dependency.new(
        name: "gtest", integration: :cmake, group: :test,
        version: "v1.17.0", hash: "SHA256=abc",
        metadata: { "repo" => "https://github.com/google/googletest" },
        post_install: hook,
      ),
    ]

    When "locking and reading back"
    lockfile.lock(deps)
    content = File.read(File.join(dir, "deps.lock"))
    read_deps = lockfile.read

    Then "post_install is absent from YAML and nil on read-back"
    !content.include?("post_install")
    read_deps[0].post_install.nil?
    read_deps[0].name == "gtest"
    read_deps[0].version == "v1.17.0"

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

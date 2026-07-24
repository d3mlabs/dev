# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/staleness"
require "dev/deps/lockfile"
require "dev/deps/dependency"
require "digest"
require "tmpdir"
require "fileutils"

transform!(RSpock::AST::Transformation)
class Dev::Deps::StalenessTest < Minitest::Test
  # A project dir with dependencies.rb plus lockfiles generated from it (the
  # manifest digest recorded in the header, like dev update-deps does).
  def build_synced_project(dir)
    project = File.join(dir, "project")
    FileUtils.mkdir_p(project)
    manifest = File.join(project, "dependencies.rb")
    File.write(manifest, "group :app do\n  cmake \"boost\", url: \"https://example.com\"\nend\n")
    lockfile = Dev::Deps::Lockfile.new(dir: project)
    lockfile.lock(
      [Dev::Deps::Dependency.new(name: "boost", integration: :cmake, group: :app,
        version: "1.90.0", hash: nil, metadata: {})],
      manifest_digest: Digest::SHA256.file(manifest).hexdigest,
    )
    project
  end

  def build_staleness(dir, project)
    Dev::Deps::Staleness.new(project_root: project, state_dir: File.join(dir, "state"))
  end

  test "a fully synced project reports no messages" do
    Given "manifest, lockfile, and stamp all in agreement"
    dir = Dir.mktmpdir("dev-staleness-test-")
    project = build_synced_project(dir)
    staleness = build_staleness(dir, project)
    staleness.stamp_installed!

    Expect
    staleness.messages == []

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "editing dependencies.rb after update-deps reports the manifest message" do
    Given "a synced project whose manifest then changes"
    dir = Dir.mktmpdir("dev-staleness-test-")
    project = build_synced_project(dir)
    staleness = build_staleness(dir, project)
    staleness.stamp_installed!
    File.write(File.join(project, "dependencies.rb"), "group :app do\nend\n")

    Expect "the fix points at update-deps"
    staleness.messages == ["dependencies.rb changed since the lockfiles were generated — run dev update-deps"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a lockfile change after the last install reports the install message" do
    Given "a stamped project whose lockfile then changes (e.g. git pull)"
    dir = Dir.mktmpdir("dev-staleness-test-")
    project = build_synced_project(dir)
    staleness = build_staleness(dir, project)
    staleness.stamp_installed!
    manifest_digest = Digest::SHA256.file(File.join(project, "dependencies.rb")).hexdigest
    Dev::Deps::Lockfile.new(dir: project).lock(
      [Dev::Deps::Dependency.new(name: "boost", integration: :cmake, group: :app,
        version: "1.91.0", hash: nil, metadata: {})],
      manifest_digest: manifest_digest,
    )

    Expect "the fix points at dev up"
    staleness.messages == ["lockfiles changed since the last install — run dev up"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a never-installed project reports the never-installed message" do
    Given "lockfiles but no stamp on this machine"
    dir = Dir.mktmpdir("dev-staleness-test-")
    project = build_synced_project(dir)
    staleness = build_staleness(dir, project)

    Expect
    staleness.messages == ["dependencies have never been installed on this machine — run dev up"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "legacy lockfiles without a manifest digest stay quiet on layer 1" do
    Given "a lockfile written before the staleness check existed, then stamped"
    dir = Dir.mktmpdir("dev-staleness-test-")
    project = File.join(dir, "project")
    FileUtils.mkdir_p(project)
    File.write(File.join(project, "dependencies.rb"), "group :app do\nend\n")
    Dev::Deps::Lockfile.new(dir: project).lock(
      [Dev::Deps::Dependency.new(name: "boost", integration: :cmake, group: :app,
        version: "1.90.0", hash: nil, metadata: {})],
    )
    staleness = build_staleness(dir, project)
    staleness.stamp_installed!

    Expect "no nag until the next update-deps records a digest"
    staleness.messages == []

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a project with no manifest and no lockfiles reports nothing" do
    Given "an empty project"
    dir = Dir.mktmpdir("dev-staleness-test-")
    project = File.join(dir, "project")
    FileUtils.mkdir_p(project)
    staleness = build_staleness(dir, project)

    Expect
    staleness.messages == []

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "stamp_installed! is a no-op without lockfiles" do
    Given "an empty project"
    dir = Dir.mktmpdir("dev-staleness-test-")
    project = File.join(dir, "project")
    FileUtils.mkdir_p(project)
    staleness = build_staleness(dir, project)

    When "stamping"
    staleness.stamp_installed!

    Then "no stamp file appears"
    !staleness.stamp_path.exist?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "two checkouts of one project keep independent stamps" do
    Given "the same project content at two paths"
    dir = Dir.mktmpdir("dev-staleness-test-")
    project_a = build_synced_project(dir)
    project_b = File.join(dir, "elsewhere", "project")
    FileUtils.mkdir_p(File.dirname(project_b))
    FileUtils.cp_r(project_a, project_b)
    staleness_a = build_staleness(dir, project_a)
    staleness_b = build_staleness(dir, project_b)

    When "installing only checkout A"
    staleness_a.stamp_installed!

    Then "checkout B still nags"
    staleness_a.messages == []
    staleness_b.messages == ["dependencies have never been installed on this machine — run dev up"]

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

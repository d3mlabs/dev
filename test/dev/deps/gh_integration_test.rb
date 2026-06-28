# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/gh_integration"
require "dev/deps/gh_repository"
require "dev/deps/cache"
require "dev/deps/dependency"
require "digest"
require "tmpdir"

# GhIntegration with the gh CLI download boundary replaced by copying
# pre-built fixture archives. Everything else (verification, extraction,
# markers) runs for real against the filesystem.
class FixtureGhIntegration < Dev::Deps::GhIntegration
  attr_reader :download_count

  def initialize(fixture_files:, **kwargs)
    super(**kwargs)
    @fixture_files = fixture_files
    @download_count = 0
  end

  private

  def download_assets(_dep, archives_dir)
    @download_count += 1
    @fixture_files.each { |file| FileUtils.cp(file, archives_dir) }
  end
end unless defined?(FixtureGhIntegration)

# GhIntegration with the gh tarball-download boundary replaced by copying a
# pre-built fixture source tarball. Extraction, the real build recipe, marker,
# and publish all run for real against the filesystem.
class FixtureSourceGhIntegration < Dev::Deps::GhIntegration
  attr_reader :download_count

  def initialize(source_tarball:, **kwargs)
    super(**kwargs)
    @source_tarball = source_tarball
    @download_count = 0
  end

  private

  def download_source(_dep, archive_path)
    @download_count += 1
    FileUtils.cp(@source_tarball, archive_path)
  end
end unless defined?(FixtureSourceGhIntegration)

transform!(RSpock::AST::Transformation)
class Dev::Deps::GhIntegrationTest < Minitest::Test
  # Build a real split zstd tarball: tar + zstd the content dir, then split
  # the compressed archive into fixed-size parts (name.tar.zst.00, .01, ...).
  #
  # @return [Array<Pathname>] the part files
  def build_split_archive(dir, base_name, part_size:)
    content_dir = File.join(dir, "content")
    FileUtils.mkdir_p(File.join(content_dir, "Engine"))
    File.write(File.join(content_dir, "Engine", "engine.txt"), "engine payload")
    File.write(File.join(content_dir, "README.md"), "readme payload")

    archive = File.join(dir, base_name)
    system("sh", "-c", "tar -cf - -C #{content_dir} . | zstd -q -o #{archive}") || raise("fixture build failed")

    bytes = File.binread(archive)
    parts = bytes.chars.each_slice(part_size).with_index.map do |slice, index|
      part = Pathname(format("%s.%02d", archive, index))
      part.binwrite(slice.join)
      part
    end
    File.delete(archive)
    parts
  end

  def build_dependency(parts, install_dir, tag: "5.6.1-css-83", sha256_overrides: {})
    assets = parts.map do |part|
      name = part.basename.to_s
      {
        "name" => name,
        "size" => part.size,
        "sha256" => sha256_overrides.fetch(name, Digest::SHA256.file(part).hexdigest),
      }
    end

    Dev::Deps::Dependency.new(
      name: "UnrealEngine", integration: :gh, group: :build,
      version: tag, hash: nil,
      metadata: {
        "repo" => "satisfactorymodding/UnrealEngine",
        "asset_pattern" => "*.tar.zst.*",
        "install_dir" => install_dir,
        "assets" => assets,
      },
    )
  end

  def build_integration(fixture_files, cache_dir)
    FixtureGhIntegration.new(
      fixture_files: fixture_files,
      repository: Dev::Deps::GhRepository.new,
      cache: Dev::Deps::Cache.new(cache_dir: cache_dir),
    )
  end

  test "install_all downloads, extracts into the version-keyed dir, and writes the marker" do
    Given "a split zstd tarball fixture and a gh dependency"
    dir = Dir.mktmpdir("dev-gh-int-test-")
    parts = build_split_archive(dir, "engine.tar.zst", part_size: 64)
    install_dir = File.join(dir, "engines", "unreal-engine-css")
    dep = build_dependency(parts, install_dir)
    integration = build_integration(parts, File.join(dir, "cache"))

    When "installing"
    integration.install_all([dep])

    Then "content + marker land under install_dir/<tag>/ and no staging remains"
    version_dir = File.join(install_dir, "5.6.1-css-83")
    File.read(File.join(version_dir, "Engine", "engine.txt")) == "engine payload"
    File.read(File.join(version_dir, "README.md")) == "readme payload"
    File.read(File.join(version_dir, ".dev-gh-release")) == "5.6.1-css-83"
    File.readlink(File.join(install_dir, "current")) == "5.6.1-css-83"
    Dir.glob(File.join(install_dir, ".staging-*")).empty?
    integration.download_count == 1

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all skips when the version dir already records the locked tag" do
    Given "a version dir with a matching marker"
    dir = Dir.mktmpdir("dev-gh-int-test-")
    parts = build_split_archive(dir, "engine.tar.zst", part_size: 64)
    install_dir = File.join(dir, "engines", "unreal-engine-css")
    version_dir = File.join(install_dir, "5.6.1-css-83")
    FileUtils.mkdir_p(version_dir)
    File.write(File.join(version_dir, ".dev-gh-release"), "5.6.1-css-83")
    dep = build_dependency(parts, install_dir)
    integration = build_integration(parts, File.join(dir, "cache"))

    When "installing again"
    integration.install_all([dep])

    Then
    integration.download_count == 0

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all installs a new version alongside the existing one when the locked tag changes" do
    Given "an existing version dir for an older tag"
    dir = Dir.mktmpdir("dev-gh-int-test-")
    parts = build_split_archive(dir, "engine.tar.zst", part_size: 64)
    install_dir = File.join(dir, "engines", "unreal-engine-css")
    old_dir = File.join(install_dir, "5.3.2-css-68")
    FileUtils.mkdir_p(old_dir)
    File.write(File.join(old_dir, ".dev-gh-release"), "5.3.2-css-68")
    File.write(File.join(old_dir, "old.txt"), "old engine")
    dep = build_dependency(parts, install_dir, tag: "5.6.1-css-83")
    integration = build_integration(parts, File.join(dir, "cache"))

    When "installing the new tag"
    integration.install_all([dep])

    Then "the new version is published while the old version coexists untouched"
    integration.download_count == 1
    File.read(File.join(install_dir, "5.6.1-css-83", ".dev-gh-release")) == "5.6.1-css-83"
    File.read(File.join(old_dir, "old.txt")) == "old engine"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all raises IntegrityError on digest mismatch and publishes no version" do
    Given "a locked digest that does not match the downloaded bytes"
    dir = Dir.mktmpdir("dev-gh-int-test-")
    parts = build_split_archive(dir, "engine.tar.zst", part_size: 64)
    install_dir = File.join(dir, "engines", "unreal-engine-css")
    corrupted = { parts.first.basename.to_s => "0" * 64 }
    dep = build_dependency(parts, install_dir, sha256_overrides: corrupted)
    integration = build_integration(parts, File.join(dir, "cache"))

    When "installing tampered assets"
    error = assert_raises(Dev::Deps::GhIntegration::IntegrityError) do
      integration.install_all([dep])
    end

    Then "no version dir is published and the staging dir is cleaned up"
    error.message.include?(parts.first.basename.to_s)
    !File.exist?(File.join(install_dir, "5.6.1-css-83"))
    Dir.glob(File.join(install_dir, ".staging-*")).empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all raises UnsupportedArchiveError for non-zstd archives" do
    Given "a downloaded asset that is not a zstd tarball"
    dir = Dir.mktmpdir("dev-gh-int-test-")
    zip_path = Pathname(File.join(dir, "engine.zip"))
    zip_path.binwrite("not actually a zip")
    install_dir = File.join(dir, "engines", "unreal-engine-css")
    dep = build_dependency([zip_path], install_dir)
    integration = build_integration([zip_path], File.join(dir, "cache"))

    When "installing the unsupported archive"
    integration.install_all([dep])

    Then
    raises Dev::Deps::GhIntegration::UnsupportedArchiveError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  # --- build-from-source path ------------------------------------------------

  # A GitHub-style source tarball: a single top-level "<repo>-<sha>/" dir that
  # the integration strips with --strip-components=1.
  #
  # @return [Pathname] the .tar.gz
  def build_source_tarball(dir, files:)
    top_name = "UnrealEngine-abc123"
    files.each do |name, content|
      path = File.join(dir, "src", top_name, name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
    tarball = Pathname(File.join(dir, "source.tar.gz"))
    system("sh", "-c", "tar -czf #{tarball} -C #{File.join(dir, "src")} #{top_name}") ||
      raise("fixture tarball build failed")
    tarball
  end

  def source_dep(install_dir, build:, tag: "5.6.1-release")
    Dev::Deps::Dependency.new(
      name: "UnrealEngine", integration: :gh, group: :game,
      version: tag, hash: nil,
      metadata: {
        "repo" => "EpicGames/UnrealEngine",
        "install_dir" => install_dir,
        "build" => build,
        "commit" => "abc123",
      },
    )
  end

  def build_source_integration(tarball, project_root, cache_dir)
    FixtureSourceGhIntegration.new(
      source_tarball: tarball,
      repository: Dev::Deps::GhRepository.new,
      cache: Dev::Deps::Cache.new(cache_dir: cache_dir),
      project_root: project_root,
    )
  end

  test "install_all builds from source via a project-relative script and publishes the output" do
    Given "a source tarball and a project build script that populates DEV_INSTALL_DIR"
    dir = Dir.mktmpdir("dev-gh-src-test-")
    tarball = build_source_tarball(dir, files: { "hello.txt" => "engine source" })
    project_root = File.join(dir, "project")
    FileUtils.mkdir_p(File.join(project_root, "bin"))
    File.write(File.join(project_root, "bin", "build.sh"), <<~SH)
      #!/usr/bin/env bash
      set -euo pipefail
      cp "$DEV_SOURCE_DIR/hello.txt" "$DEV_INSTALL_DIR/built.txt"
      echo "$DEV_VERSION" > "$DEV_INSTALL_DIR/version.txt"
    SH
    install_dir = File.join(dir, "engines", "ue5")
    dep = source_dep(install_dir, build: "bin/build.sh")
    integration = build_source_integration(tarball, project_root, File.join(dir, "cache"))

    When "installing"
    integration.install_all([dep])

    Then "the build output lands under install_dir/<tag>/ with the marker, no staging remains"
    version_dir = File.join(install_dir, "5.6.1-release")
    File.read(File.join(version_dir, "built.txt")) == "engine source"
    File.read(File.join(version_dir, "version.txt")).strip == "5.6.1-release"
    File.read(File.join(version_dir, ".dev-gh-release")) == "5.6.1-release"
    File.readlink(File.join(install_dir, "current")) == "5.6.1-release"
    Dir.glob(File.join(install_dir, ".staging-*")).empty?
    integration.download_count == 1

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all with build: none publishes the extracted source tree unchanged" do
    Given "a source tarball and a header-only (build: none) dependency"
    dir = Dir.mktmpdir("dev-gh-src-test-")
    tarball = build_source_tarball(dir, files: { "include/lib.h" => "#pragma once" })
    install_dir = File.join(dir, "libs", "headeronly")
    dep = source_dep(install_dir, build: "none", tag: "v1.0")
    integration = build_source_integration(tarball, File.join(dir, "project"), File.join(dir, "cache"))

    When "installing"
    integration.install_all([dep])

    Then "the source tree itself becomes the version dir, marker included"
    version_dir = File.join(install_dir, "v1.0")
    File.read(File.join(version_dir, "include", "lib.h")) == "#pragma once"
    File.read(File.join(version_dir, ".dev-gh-release")) == "v1.0"
    Dir.glob(File.join(install_dir, ".staging-*")).empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all skips the source build when the version dir already records the tag" do
    Given "a version dir with a matching marker"
    dir = Dir.mktmpdir("dev-gh-src-test-")
    tarball = build_source_tarball(dir, files: { "hello.txt" => "x" })
    install_dir = File.join(dir, "engines", "ue5")
    version_dir = File.join(install_dir, "5.6.1-release")
    FileUtils.mkdir_p(version_dir)
    File.write(File.join(version_dir, ".dev-gh-release"), "5.6.1-release")
    dep = source_dep(install_dir, build: "bin/build.sh")
    integration = build_source_integration(tarball, File.join(dir, "project"), File.join(dir, "cache"))

    When "installing again"
    integration.install_all([dep])

    Then
    integration.download_count == 0

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all raises BuildError and publishes no version when the build recipe fails" do
    Given "a build recipe that exits non-zero"
    dir = Dir.mktmpdir("dev-gh-src-test-")
    tarball = build_source_tarball(dir, files: { "hello.txt" => "x" })
    install_dir = File.join(dir, "engines", "ue5")
    dep = source_dep(install_dir, build: "exit 7")
    integration = build_source_integration(tarball, File.join(dir, "project"), File.join(dir, "cache"))

    When "installing"
    error = assert_raises(Dev::Deps::GhIntegration::BuildError) do
      integration.install_all([dep])
    end

    Then "no version dir is published and staging is cleaned up"
    error.message.include?("UnrealEngine")
    !File.exist?(File.join(install_dir, "5.6.1-release"))
    Dir.glob(File.join(install_dir, ".staging-*")).empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

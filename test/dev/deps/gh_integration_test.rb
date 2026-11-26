# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/gh_integration"
require "dev/deps/gh_repository"
require "dev/deps/local_store"
require "dev/deps/dependency"
require "digest"
require "support/recording_ui"
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

# The brew a self-contained tree asks for its Ruby, with the brew writes
# replaced: it records what it was asked to install and answers a keg laid
# out by the test.
class RecordingBrew < Dev::Deps::BrewIntegration
  attr_reader :installed

  def initialize(keg:, **kwargs)
    super(**kwargs)
    @keg = keg
    @installed = []
  end

  def install_all(dependencies)
    @installed.concat(dependencies)
  end

  def keg(_dep)
    @keg
  end
end unless defined?(RecordingBrew)

# GhIntegration with per-dep install replaced by a recorder that raises for
# configured dep names — exercises install_all's failure isolation without
# any download machinery.
class ExplodingGhIntegration < Dev::Deps::GhIntegration
  attr_reader :attempted

  def initialize(fail_names:, **kwargs)
    super(**kwargs)
    @fail_names = fail_names
    @attempted = []
  end

  private

  def install(dep)
    @attempted << dep.name
    raise "release asset missing for #{dep.name}" if @fail_names.include?(dep.name)
  end
end unless defined?(ExplodingGhIntegration)

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

  def build_zip_archive(dir, name)
    content_dir = File.join(dir, "content")
    FileUtils.mkdir_p(File.join(content_dir, "Engine"))
    File.write(File.join(content_dir, "Engine", "engine.txt"), "engine payload")
    File.write(File.join(content_dir, "README.md"), "readme payload")

    archive = Pathname(File.join(dir, name))
    system("zip", "-r", "-q", archive.to_s, ".", chdir: content_dir) || raise("fixture build failed")
    archive
  end

  def build_dependency(parts, tag: "5.6.1-css-83", sha256_overrides: {},
                       asset_pattern: "*.tar.zst.*")
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
        "asset_pattern" => asset_pattern,
        "assets" => assets,
      },
    )
  end

  def build_integration(fixture_files, data_root, ui: RecordingUi.new)
    FixtureGhIntegration.new(
      fixture_files: fixture_files,
      repository: Dev::Deps::GhRepository.new,
      store: Dev::Deps::LocalStore.new(data_root: data_root),
      ui: ui,
    )
  end

  test "a fresh install speaks through the Ui (dev#573): steps for the children handed the terminal, a spin for the digest check, then the fact of where it landed" do
    Given "a split zstd tarball fixture and a gh dependency, over a recording Ui"
    dir = Dir.mktmpdir("dev-gh-int-test-")
    parts = build_split_archive(dir, "engine.tar.zst", part_size: 64)
    dep = build_dependency(parts)
    ui = RecordingUi.new
    integration = build_integration(parts, dir, ui: ui)

    When "installing"
    integration.install_all([dep])

    Then
    ui.rows == [
      [:step, "Downloading UnrealEngine@5.6.1-css-83 from satisfactorymodding/UnrealEngine", 0],
      [:spin, "Verifying UnrealEngine@5.6.1-css-83", 0],
      [:step, "Extracting UnrealEngine@5.6.1-css-83", 0],
      [:note, "{{v}} UnrealEngine@5.6.1-css-83 installed at #{File.join(dir, "gh", "satisfactorymodding", "UnrealEngine", "5.6.1-css-83")}", 0],
    ]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "an installed tree is one fact on the Ui, and nothing runs" do
    Given "a version dir with a matching marker, over a recording Ui"
    dir = Dir.mktmpdir("dev-gh-int-test-")
    parts = build_split_archive(dir, "engine.tar.zst", part_size: 64)
    version_dir = File.join(dir, "gh", "satisfactorymodding", "UnrealEngine", "5.6.1-css-83")
    FileUtils.mkdir_p(version_dir)
    File.write(File.join(version_dir, ".dev-gh-release"), "5.6.1-css-83")
    ui = RecordingUi.new
    integration = build_integration(parts, dir, ui: ui)

    When "installing again"
    integration.install_all([build_dependency(parts)])

    Then
    ui.rows == [[:note, "{{v}} UnrealEngine@5.6.1-css-83 is installed at #{version_dir}", 0]]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "tree_key places a gh tree by identity: ~/.dev/gh/<owner>/<repo>/<tag>" do
    Given "a locked gh dep"
    dep = build_dependency([], tag: "5.8.0-wine-8")

    When "asking where its tree lives"
    key = Dev::Deps::GhIntegration.tree_key(dep)

    Then "the base is the source slug under the gh root, the version the tag, the marker gh's"
    [key.base, key.version, key.marker, key.platform] ==
      ["~/.dev/gh/satisfactorymodding/UnrealEngine", "5.8.0-wine-8", Dev::Deps::GhIntegration::MARKER_FILE, nil]
  end

  test "tree_key is the same tree for two projects naming one release differently" do
    Given "two declarations of the same repo and tag under different names"
    a = build_dependency([], tag: "toolchain-2").with(name: "MsvcWineToolchain")
    b = build_dependency([], tag: "toolchain-2").with(name: "Toolchain")

    When "placing both"
    keys = [a, b].map { |dep| Dev::Deps::GhIntegration.tree_key(dep) }

    Then "one place: the name is the project's alias, the identity is the repo"
    keys.map { |key| [key.base, key.version, key.marker] }.uniq.size == 1
  end

  test "install_all downloads, extracts into the version-keyed dir, and writes the marker" do
    Given "a split zstd tarball fixture and a gh dependency"
    dir = Dir.mktmpdir("dev-gh-int-test-")
    parts = build_split_archive(dir, "engine.tar.zst", part_size: 64)
    tree_dir = File.join(dir, "gh", "satisfactorymodding", "UnrealEngine")
    dep = build_dependency(parts)
    integration = build_integration(parts, dir)

    When "installing"
    integration.install_all([dep])

    Then "content + marker land under the identity base/<tag>/ and no staging remains"
    version_dir = File.join(tree_dir, "5.6.1-css-83")
    File.read(File.join(version_dir, "Engine", "engine.txt")) == "engine payload"
    File.read(File.join(version_dir, "README.md")) == "readme payload"
    File.read(File.join(version_dir, ".dev-gh-release")) == "5.6.1-css-83"
    !File.exist?(File.join(tree_dir, "current"))
    Dir.glob(File.join(tree_dir, ".staging-*")).empty?
    integration.download_count == 1

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all skips when the version dir already records the locked tag" do
    Given "a version dir with a matching marker"
    dir = Dir.mktmpdir("dev-gh-int-test-")
    parts = build_split_archive(dir, "engine.tar.zst", part_size: 64)
    tree_dir = File.join(dir, "gh", "satisfactorymodding", "UnrealEngine")
    version_dir = File.join(tree_dir, "5.6.1-css-83")
    FileUtils.mkdir_p(version_dir)
    File.write(File.join(version_dir, ".dev-gh-release"), "5.6.1-css-83")
    dep = build_dependency(parts)
    integration = build_integration(parts, dir)

    When "installing again"
    integration.install_all([dep])

    Then
    integration.download_count == 0

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all on an already-published version writes nothing — a read-only shared tree stays usable" do
    Given "a published version in a base dir the caller cannot write (the agent identity on " \
          "the human-owned shared engine tree, plans#26)"
    dir = Dir.mktmpdir("dev-gh-int-test-")
    parts = build_split_archive(dir, "engine.tar.zst", part_size: 64)
    tree_dir = File.join(dir, "gh", "satisfactorymodding", "UnrealEngine")
    version_dir = File.join(tree_dir, "5.6.1-css-83")
    FileUtils.mkdir_p(version_dir)
    File.write(File.join(version_dir, ".dev-gh-release"), "5.6.1-css-83")
    FileUtils.chmod(0o555, tree_dir)
    dep = build_dependency(parts)
    integration = build_integration(parts, dir)

    When "installing again"
    integration.install_all([dep])

    Then "the marker was recognized and no write was attempted (the retired current-pointer " \
         "rewrite crashed dev deps install here with EACCES at the plans#36 ceremony)"
    !File.exist?(File.join(tree_dir, "current"))
    integration.download_count == 0

    Cleanup
    FileUtils.chmod(0o755, tree_dir)
    FileUtils.rm_rf(dir)
  end

  test "install_all installs a new version alongside the existing one when the locked tag changes" do
    Given "an existing version dir for an older tag"
    dir = Dir.mktmpdir("dev-gh-int-test-")
    parts = build_split_archive(dir, "engine.tar.zst", part_size: 64)
    tree_dir = File.join(dir, "gh", "satisfactorymodding", "UnrealEngine")
    old_dir = File.join(tree_dir, "5.3.2-css-68")
    FileUtils.mkdir_p(old_dir)
    File.write(File.join(old_dir, ".dev-gh-release"), "5.3.2-css-68")
    File.write(File.join(old_dir, "old.txt"), "old engine")
    dep = build_dependency(parts, tag: "5.6.1-css-83")
    integration = build_integration(parts, dir)

    When "installing the new tag"
    integration.install_all([dep])

    Then "the new version is published while the old version coexists untouched"
    integration.download_count == 1
    File.read(File.join(tree_dir, "5.6.1-css-83", ".dev-gh-release")) == "5.6.1-css-83"
    File.read(File.join(old_dir, "old.txt")) == "old engine"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all raises IntegrityError on digest mismatch and publishes no version" do
    Given "a locked digest that does not match the downloaded bytes"
    dir = Dir.mktmpdir("dev-gh-int-test-")
    parts = build_split_archive(dir, "engine.tar.zst", part_size: 64)
    tree_dir = File.join(dir, "gh", "satisfactorymodding", "UnrealEngine")
    corrupted = { parts.first.basename.to_s => "0" * 64 }
    dep = build_dependency(parts, sha256_overrides: corrupted)
    integration = build_integration(parts, dir)

    When "installing tampered assets"
    error = assert_raises(Dev::Deps::Integration::PartialInstallError) do
      integration.install_all([dep])
    end

    Then "no version dir is published and the staging dir is cleaned up"
    error.failures[0][1].is_a?(Dev::Deps::GhIntegration::IntegrityError)
    error.message.include?(parts.first.basename.to_s)
    !File.exist?(File.join(tree_dir, "5.6.1-css-83"))
    Dir.glob(File.join(tree_dir, ".staging-*")).empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all extracts a zip asset — the archive packager's default form — into the version dir" do
    Given "a release asset `dev package` wrote as a zip"
    dir = Dir.mktmpdir("dev-gh-int-test-")
    zip_path = build_zip_archive(dir, "ai-flow-1.1.0.zip")
    tree_dir = File.join(dir, "gh", "satisfactorymodding", "UnrealEngine")
    dep = build_dependency([zip_path], asset_pattern: "*.zip")
    integration = build_integration([zip_path], dir)

    When "installing"
    integration.install_all([dep])

    Then "the tree is the zip's contents, published like a tarball's"
    File.read(File.join(tree_dir, "5.6.1-css-83", "Engine", "engine.txt")) == "engine payload"
    File.read(File.join(tree_dir, "5.6.1-css-83", "README.md")) == "readme payload"
    File.read(File.join(tree_dir, "5.6.1-css-83", ".dev-gh-release")) == "5.6.1-css-83"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all raises ExtractionError when the zip does not unpack" do
    Given "an asset named as a zip whose bytes are not one"
    dir = Dir.mktmpdir("dev-gh-int-test-")
    zip_path = Pathname(File.join(dir, "ai-flow-1.1.0.zip"))
    zip_path.binwrite("not actually a zip")
    dep = build_dependency([zip_path], asset_pattern: "*.zip")
    integration = build_integration([zip_path], dir)

    When "installing"
    error = assert_raises(Dev::Deps::Integration::PartialInstallError) do
      integration.install_all([dep])
    end

    Then "the per-dep failure is the extraction, naming the archive"
    error.failures[0][1].is_a?(Dev::Deps::GhIntegration::ExtractionError)
    error.message.include?("extraction failed for ai-flow-1.1.0.zip")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all raises UnsupportedArchiveError for an archive in neither form the packager writes" do
    Given "a downloaded asset that is neither a zip nor a zstd tarball"
    dir = Dir.mktmpdir("dev-gh-int-test-")
    gz_path = Pathname(File.join(dir, "engine.tar.gz"))
    gz_path.binwrite("not actually a tarball")
    dep = build_dependency([gz_path], asset_pattern: "*.tar.gz")
    integration = build_integration([gz_path], dir)

    When "installing the unsupported archive"
    error = assert_raises(Dev::Deps::Integration::PartialInstallError) do
      integration.install_all([dep])
    end

    Then "the per-dep failure is the archive rejection, naming both forms"
    error.failures[0][1].is_a?(Dev::Deps::GhIntegration::UnsupportedArchiveError)
    error.message.include?(".zip or .tar.zst[.NN]")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all raises NoMatchingAssetsError when the glob selects no locked asset" do
    Given "a locked asset list the declared glob does not cover"
    dir = Dir.mktmpdir("dev-gh-int-test-")
    parts = build_split_archive(dir, "engine.tar.zst", part_size: 64)
    tree_dir = File.join(dir, "gh", "satisfactorymodding", "UnrealEngine")
    dep = build_dependency(parts, asset_pattern: "*.7z.*")
    integration = build_integration(parts, dir)

    When "installing with a glob that matches nothing"
    error = assert_raises(Dev::Deps::Integration::PartialInstallError) do
      integration.install_all([dep])
    end

    Then "the mismatch is loud — never a silently empty install"
    error.failures[0][1].is_a?(Dev::Deps::GhIntegration::NoMatchingAssetsError)

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

  def source_dep(build:, tag: "5.6.1-release")
    Dev::Deps::Dependency.new(
      name: "UnrealEngine", integration: :gh, group: :game,
      version: tag, hash: nil,
      metadata: {
        "repo" => "EpicGames/UnrealEngine",
        "build" => build,
        "commit" => "abc123",
      },
    )
  end

  def build_source_integration(tarball, project_root, data_root)
    FixtureSourceGhIntegration.new(
      source_tarball: tarball,
      repository: Dev::Deps::GhRepository.new,
      store: Dev::Deps::LocalStore.new(data_root: data_root),
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
    tree_dir = File.join(dir, "gh", "EpicGames", "UnrealEngine")
    dep = source_dep(build: "bin/build.sh")
    integration = build_source_integration(tarball, project_root, dir)

    When "installing"
    integration.install_all([dep])

    Then "the build output lands under the identity base/<tag>/ with the marker, no staging remains"
    version_dir = File.join(tree_dir, "5.6.1-release")
    File.read(File.join(version_dir, "built.txt")) == "engine source"
    File.read(File.join(version_dir, "version.txt")).strip == "5.6.1-release"
    File.read(File.join(version_dir, ".dev-gh-release")) == "5.6.1-release"
    !File.exist?(File.join(tree_dir, "current"))
    Dir.glob(File.join(tree_dir, ".staging-*")).empty?
    integration.download_count == 1

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all with build: none publishes the extracted source tree unchanged" do
    Given "a source tarball and a header-only (build: none) dependency"
    dir = Dir.mktmpdir("dev-gh-src-test-")
    tarball = build_source_tarball(dir, files: { "include/lib.h" => "#pragma once" })
    tree_dir = File.join(dir, "gh", "EpicGames", "UnrealEngine")
    dep = source_dep(build: "none", tag: "v1.0")
    integration = build_source_integration(tarball, File.join(dir, "project"), dir)

    When "installing"
    integration.install_all([dep])

    Then "the source tree itself becomes the version dir, marker included"
    version_dir = File.join(tree_dir, "v1.0")
    File.read(File.join(version_dir, "include", "lib.h")) == "#pragma once"
    File.read(File.join(version_dir, ".dev-gh-release")) == "v1.0"
    Dir.glob(File.join(tree_dir, ".staging-*")).empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all materializes a sha: pin from source under gh/<slug>/<sha> — the SHA is the version" do
    Given "a header-only dependency pinned at a commit"
    dir = Dir.mktmpdir("dev-gh-src-test-")
    tarball = build_source_tarball(dir, files: { "include/lib.h" => "#pragma once" })
    sha = "9cca280a4d0ccf0c08f47a99aa71d1b0e52f8d03"
    tree_dir = File.join(dir, "gh", "EpicGames", "UnrealEngine")
    dep = source_dep(build: "none", tag: sha).with(metadata: { "repo" => "EpicGames/UnrealEngine", "build" => "none" })
    integration = build_source_integration(tarball, File.join(dir, "project"), dir)

    When "installing"
    integration.install_all([dep])

    Then "the tree is keyed by the commit and the marker records it"
    version_dir = File.join(tree_dir, sha)
    File.read(File.join(version_dir, "include", "lib.h")) == "#pragma once"
    File.read(File.join(version_dir, ".dev-gh-release")) == sha
    integration.download_count == 1

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "download_source fetches the locked version's tarball as written — a sha: pin by its commit" do
    Given "a dependency pinned at a commit and an integration speaking to gh"
    dir = Dir.mktmpdir("dev-gh-src-test-")
    sha = "9cca280a4d0ccf0c08f47a99aa71d1b0e52f8d03"
    dep = source_dep(build: "none", tag: sha).with(metadata: { "repo" => "nlohmann/json", "build" => "none" })
    integration = Dev::Deps::GhIntegration.new(
      repository: Dev::Deps::GhRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir),
    )
    archive_path = Pathname(File.join(dir, "source.tar.gz"))
    integration.expects(:system)
               .with("gh", "api", "repos/nlohmann/json/tarball/#{sha}", out: archive_path.to_s)
               .returns(true)

    When "fetching"
    integration.send(:download_source, dep, archive_path)

    Then "the tarball endpoint resolves the commit; no release is consulted"
    true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "download_source raises DownloadError when the repo has no such commit — the address's existence check" do
    Given "a sha: pin GitHub answers 404 for"
    dir = Dir.mktmpdir("dev-gh-src-test-")
    sha = "0000000000000000000000000000000000000000"
    dep = source_dep(build: "none", tag: sha).with(metadata: { "repo" => "nlohmann/json", "build" => "none" })
    integration = Dev::Deps::GhIntegration.new(
      repository: Dev::Deps::GhRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir),
    )
    integration.stubs(:system).returns(false)

    When "fetching"
    integration.send(:download_source, dep, Pathname(File.join(dir, "source.tar.gz")))

    Then
    raises Dev::Deps::GhIntegration::DownloadError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all skips the source build when the version dir already records the tag" do
    Given "a version dir with a matching marker"
    dir = Dir.mktmpdir("dev-gh-src-test-")
    tarball = build_source_tarball(dir, files: { "hello.txt" => "x" })
    tree_dir = File.join(dir, "gh", "EpicGames", "UnrealEngine")
    version_dir = File.join(tree_dir, "5.6.1-release")
    FileUtils.mkdir_p(version_dir)
    File.write(File.join(version_dir, ".dev-gh-release"), "5.6.1-release")
    dep = source_dep(build: "bin/build.sh")
    integration = build_source_integration(tarball, File.join(dir, "project"), dir)

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
    tree_dir = File.join(dir, "gh", "EpicGames", "UnrealEngine")
    dep = source_dep(build: "exit 7")
    integration = build_source_integration(tarball, File.join(dir, "project"), dir)

    When "installing"
    error = assert_raises(Dev::Deps::Integration::PartialInstallError) do
      integration.install_all([dep])
    end

    Then "no version dir is published and staging is cleaned up"
    error.failures[0][1].is_a?(Dev::Deps::GhIntegration::BuildError)
    error.message.include?("UnrealEngine")
    !File.exist?(File.join(tree_dir, "5.6.1-release"))
    Dir.glob(File.join(tree_dir, ".staging-*")).empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  # --- a self-contained tree (dev#656, dev#677) -------------------------------

  TOOL_LOCK = <<~YAML
    # Generated by dev. Do not edit.

    ruby:
      ruby:
        group: app
        version: 4.0.6
        tap: d3mlabs/d3mlabs
        version_suffix: 4.0.6
  YAML

  # The files of a self-contained tree's release: manifest, lock, Gemfile (unless
  # ruby-only), its executable — and, for a release that vendored, the gems.
  #
  # @return [Hash{String => String}] path → content, for build_source_tarball
  def tool_files(lock: TOOL_LOCK, gemfile: true, vendored: false)
    files = {
      "dependencies.rb" => "Dev::Deps.define { ruby \"4.0.6\" }\n",
      "deps.lock" => lock,
      "exe/ai-flow" => "#!/usr/bin/env ruby\nputs 'dispatching'\n",
    }
    files["Gemfile"] = %(source "https://rubygems.org"\n) if gemfile
    files["vendor/bundle/ruby/4.0.0/.keep"] = "" if vendored
    files
  end

  # A keg whose `bin/bundle` is a stand-in: it records the env it ran with
  # and lays the vendor dir bundler would, so the test reads real files.
  #
  # @param dir [String]
  # @return [Pathname] the keg
  def lay_keg(dir)
    keg = Pathname(dir) / "homebrew/Cellar/ruby@4.0.6/4.0.6"
    (keg / "bin").mkpath
    (keg / "bin/bundle").write(<<~SH)
      #!/bin/sh
      env | grep '^BUNDLE_' | sort > "#{dir}/bundle-env.txt"
      echo "$*" > "#{dir}/bundle-argv.txt"
      mkdir -p "$BUNDLE_PATH/ruby/4.0.0"
    SH
    (keg / "bin/bundle").chmod(0o755)
    keg
  end

  def tool_dep(tag: "v1.0.0")
    Dev::Deps::Dependency.new(
      name: "ai-flow", integration: :gh, group: :app,
      version: tag, hash: nil,
      metadata: { "repo" => "d3mlabs/ai-flow", "build" => "none", "commit" => "abc123" },
    )
  end

  def build_tool_integration(tarball, dir, brew:, ui: RecordingUi.new)
    FixtureSourceGhIntegration.new(
      source_tarball: tarball,
      repository: Dev::Deps::GhRepository.new,
      store: Dev::Deps::LocalStore.new(data_root: dir),
      brew: brew,
      ui: ui,
    )
  end

  test "a tree carrying dependencies.rb and deps.lock is installed self-contained before it publishes: the lock's Ruby through brew, the gems vendored under the keg's bundler into the store's cache, launchers in bin/" do
    Given "a self-contained tree's release, a keg for its Ruby, and a brew that answers it"
    dir = Dir.mktmpdir("dev-gh-tool-test-")
    tarball = build_source_tarball(dir, files: tool_files)
    keg = lay_keg(dir)
    brew = RecordingBrew.new(keg:, repository: nil, store: nil)
    ui = RecordingUi.new
    integration = build_tool_integration(tarball, dir, brew:, ui:)

    When "installing"
    integration.install_all([tool_dep])

    Then "brew was asked for the lock's ruby pin and only it; the gems were bundled frozen into the tree's own " \
         "vendor/bundle, caching in the store; the launcher runs exe/ai-flow under the keg's Ruby; the tree published"
    brew.installed.map { |dep| [dep.integration, dep.version, dep.metadata["version_suffix"]] } == [[:ruby, "4.0.6", "4.0.6"]]
    tree = Pathname(dir) / "gh/d3mlabs/ai-flow/v1.0.0"
    File.read(File.join(dir, "bundle-argv.txt")) == "install\n"
    # The bundle ran in the staging tree under the base; the published
    # tree's launcher resolves the final path at run time, so the move cost
    # nothing. The suite's own harness keys ride along (the seam clears
    # nothing; bin/dev scrubs them once in production), so only the keys
    # the vendoring sets are read.
    staging = %r{\A#{Regexp.escape(dir)}/gh/d3mlabs/ai-flow/\.staging-[^/]+/source}
    bundle_env = File.read(File.join(dir, "bundle-env.txt")).lines(chomp: true).to_h { |line| line.split("=", 2) }
    bundle_env.fetch("BUNDLE_GEMFILE").match?(%r{#{staging}/Gemfile\z})
    bundle_env.fetch("BUNDLE_PATH").match?(%r{#{staging}/vendor/bundle\z})
    bundle_env.slice("BUNDLE_FROZEN", "BUNDLE_WITHOUT", "BUNDLE_DISABLE_SHARED_GEMS", "BUNDLE_GLOBAL_GEM_CACHE", "BUNDLE_USER_CACHE") == {
      "BUNDLE_FROZEN" => "true",
      "BUNDLE_WITHOUT" => "development:test",
      "BUNDLE_DISABLE_SHARED_GEMS" => "true",
      "BUNDLE_GLOBAL_GEM_CACHE" => "true",
      "BUNDLE_USER_CACHE" => "#{dir}/tool-caches/bundler",
    }
    Dir.glob(File.join(dir, "gh/d3mlabs/ai-flow/.staging-*")).empty?
    (tree / "vendor/bundle/ruby/4.0.0").directory?
    (tree / "bin/ai-flow").executable?
    (tree / "bin/ai-flow").read.include?(%(tree="$(cd "$(dirname "$0")/.." && pwd -P)"))
    (tree / "bin/ai-flow").read.lines.last == %(exec #{keg}/bin/ruby "$tree/exe/ai-flow" "$@"\n)
    (tree / ".dev-gh-release").read == "v1.0.0"
    ui.rows.include?([:spin, "Vendoring ai-flow@v1.0.0's gems under 4.0.6", 0])
    ui.rows.include?([:note, "{{v}} ai-flow@v1.0.0 is self-contained: ruby 4.0.6, 1 launcher(s) in bin/", 0])

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a release that vendored its gems gets launchers only: the keg still, no bundle install" do
    Given "a self-contained tree whose release carries vendor/bundle"
    dir = Dir.mktmpdir("dev-gh-tool-test-")
    tarball = build_source_tarball(dir, files: tool_files(vendored: true))
    keg = lay_keg(dir)
    brew = RecordingBrew.new(keg:, repository: nil, store: nil)
    ui = RecordingUi.new
    integration = build_tool_integration(tarball, dir, brew:, ui:)

    When
    integration.install_all([tool_dep])

    Then
    brew.installed.size == 1
    !File.exist?(File.join(dir, "bundle-argv.txt"))
    tree = Pathname(dir) / "gh/d3mlabs/ai-flow/v1.0.0"
    (tree / "bin/ai-flow").read.lines.last == %(exec #{keg}/bin/ruby "$tree/exe/ai-flow" "$@"\n)
    ui.rows.include?([:note, "{{v}} ai-flow@v1.0.0 ships its gems vendored", 0])
    ui.rows.none? { |row| row[0] == :spin && row[1].start_with?("Vendoring") }

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a Ruby-only self-contained tree (no Gemfile) gets the keg and the same launcher, with no bundle install" do
    Given
    dir = Dir.mktmpdir("dev-gh-tool-test-")
    tarball = build_source_tarball(dir, files: tool_files(gemfile: false))
    keg = lay_keg(dir)
    integration = build_tool_integration(tarball, dir, brew: RecordingBrew.new(keg:, repository: nil, store: nil))

    When
    integration.install_all([tool_dep])

    Then
    !File.exist?(File.join(dir, "bundle-argv.txt"))
    launcher = Pathname(dir).join("gh/d3mlabs/ai-flow/v1.0.0/bin/ai-flow").read
    launcher.lines.last == %(exec #{keg}/bin/ruby "$tree/exe/ai-flow" "$@"\n)
    !launcher.include?("export ")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a self-contained tree whose lock pins no Ruby is this dep's failure and publishes nothing" do
    Given
    dir = Dir.mktmpdir("dev-gh-tool-test-")
    tarball = build_source_tarball(dir, files: tool_files(lock: "brew:\n  zstd:\n    group: app\n    version: 1.5.6\n"))
    brew = RecordingBrew.new(keg: lay_keg(dir), repository: nil, store: nil)
    integration = build_tool_integration(tarball, dir, brew:)

    When
    error = assert_raises(Dev::Deps::Integration::PartialInstallError) { integration.install_all([tool_dep]) }

    Then
    error.failures[0][1].is_a?(Dev::Deps::SelfContainedTree::GemBundle::NoRubyPinError)
    brew.installed.empty?
    !File.exist?(File.join(dir, "gh/d3mlabs/ai-flow/v1.0.0"))
    Dir.glob(File.join(dir, "gh/d3mlabs/ai-flow/.staging-*")).empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a failed bundle install is this dep's failure: nothing publishes, the next install starts clean" do
    Given "a keg whose bundle refuses"
    dir = Dir.mktmpdir("dev-gh-tool-test-")
    tarball = build_source_tarball(dir, files: tool_files)
    keg = lay_keg(dir)
    (keg / "bin/bundle").write("#!/bin/sh\necho 'Could not find gem' >&2\nexit 5\n")
    integration = build_tool_integration(tarball, dir, brew: RecordingBrew.new(keg:, repository: nil, store: nil))

    When
    error = assert_raises(Dev::Deps::Integration::PartialInstallError) { integration.install_all([tool_dep]) }

    Then
    error.failures[0][1].is_a?(Dev::Deps::SelfContainedTree::GemBundle::VendorError)
    error.message.include?("Could not find gem")
    !File.exist?(File.join(dir, "gh/d3mlabs/ai-flow/v1.0.0"))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a prebuilt asset that ships its manifest and lock is installed self-contained the same way" do
    Given "a split zstd release of a self-contained tree"
    dir = Dir.mktmpdir("dev-gh-tool-test-")
    content_dir = File.join(dir, "content")
    tool_files(gemfile: false).each do |path, body|
      FileUtils.mkdir_p(File.dirname(File.join(content_dir, path)))
      File.write(File.join(content_dir, path), body)
    end
    archive = File.join(dir, "ai-flow.tar.zst")
    system("sh", "-c", "tar -cf - -C #{content_dir} . | zstd -q -o #{archive}") || raise("fixture build failed")
    part = Pathname("#{archive}.00")
    FileUtils.mv(archive, part)
    keg = lay_keg(dir)
    integration = FixtureGhIntegration.new(
      fixture_files: [part], repository: Dev::Deps::GhRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir),
      brew: RecordingBrew.new(keg:, repository: nil, store: nil),
    )
    dep = build_dependency([part], tag: "v1.0.0").with(name: "ai-flow", metadata: {
      "repo" => "d3mlabs/ai-flow", "asset_pattern" => "*.tar.zst.*",
      "assets" => [{ "name" => part.basename.to_s, "size" => part.size, "sha256" => Digest::SHA256.file(part).hexdigest }],
    })

    When
    integration.install_all([dep])

    Then
    Pathname(dir).join("gh/d3mlabs/ai-flow/v1.0.0/bin/ai-flow").read.lines.last == %(exec #{keg}/bin/ruby "$tree/exe/ai-flow" "$@"\n)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a tree without a manifest and lock is a plain asset: brew is never asked" do
    Given
    dir = Dir.mktmpdir("dev-gh-tool-test-")
    tarball = build_source_tarball(dir, files: { "include/lib.h" => "#pragma once" })
    brew = RecordingBrew.new(keg: lay_keg(dir), repository: nil, store: nil)
    integration = build_tool_integration(tarball, dir, brew:)

    When
    integration.install_all([source_dep(build: "none", tag: "v1.0").with(metadata: { "repo" => "EpicGames/UnrealEngine", "build" => "none" })])

    Then
    brew.installed.empty?
    !File.exist?(File.join(dir, "gh/EpicGames/UnrealEngine/v1.0/bin"))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  # Publish a version dir by hand: marker plus optional `bin/`.
  #
  # @param data_root [String]
  # @param repo [String] owner/repo
  # @param tag [String]
  # @param with_bin [Boolean]
  # @return [String] the version dir
  def publish_tree(data_root, repo:, tag:, with_bin:)
    version_dir = File.join(data_root, "gh", repo, tag)
    FileUtils.mkdir_p(version_dir)
    FileUtils.mkdir_p(File.join(version_dir, "bin")) if with_bin
    File.write(File.join(version_dir, ".dev-gh-release"), tag)
    version_dir
  end

  # @param project_root [String]
  # @return [String] what the gh activation file holds, "" when absent
  def gh_lisp(project_root)
    path = File.join(project_root, ".shadowenv.d", Dev::Deps::GhIntegration::LISP_FILENAME)
    File.exist?(path) ? File.read(path) : ""
  end

  test "install_all puts a published tree's bin on the project PATH" do
    Given "a toolchain tree already published with a bin, and a project"
    dir = Dir.mktmpdir("dev-gh-int-test-")
    project = File.join(dir, "project")
    FileUtils.mkdir_p(project)
    version_dir = publish_tree(dir, repo: "d3mlabs/unreal-engine-build-base", tag: "toolchain-2", with_bin: true)
    integration = Dev::Deps::GhIntegration.new(
      repository: Dev::Deps::GhRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir), project_root: project,
    )
    dep = Dev::Deps::Dependency.new(name: "MsvcWineToolchain", integration: :gh, group: :build,
      version: "toolchain-2", hash: nil,
      metadata: { "repo" => "d3mlabs/unreal-engine-build-base", "asset_pattern" => "*.tar.zst.*", "assets" => [] })

    When "installing"
    integration.install_all([dep])

    Then "the activation prepends the tree's bin and names the tree"
    _ * Kernel.system >> true
    gh_lisp(project).include?(%((env/prepend-to-pathlist "PATH" "#{version_dir}/bin")))
    gh_lisp(project).include?('(provide "gh" "MsvcWineToolchain@toolchain-2")')

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all activates nothing for a tree without a bin, and names it still" do
    Given "an engine tree with no bin"
    dir = Dir.mktmpdir("dev-gh-int-test-")
    project = File.join(dir, "project")
    FileUtils.mkdir_p(project)
    publish_tree(dir, repo: "satisfactorymodding/UnrealEngine", tag: "5.6.1-css-83", with_bin: false)
    integration = Dev::Deps::GhIntegration.new(
      repository: Dev::Deps::GhRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir), project_root: project,
    )
    dep = Dev::Deps::Dependency.new(name: "UnrealEngine", integration: :gh, group: :build,
      version: "5.6.1-css-83", hash: nil,
      metadata: { "repo" => "satisfactorymodding/UnrealEngine", "asset_pattern" => "*.tar.zst.*", "assets" => [] })

    When "installing"
    integration.install_all([dep])

    Then
    _ * Kernel.system >> true
    gh_lisp(project) == %((provide "gh" "UnrealEngine@5.6.1-css-83")\n)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all without a project root activates nothing" do
    Given "a published tree with a bin, and an integration that knows no project"
    dir = Dir.mktmpdir("dev-gh-int-test-")
    publish_tree(dir, repo: "d3mlabs/unreal-engine-build-base", tag: "toolchain-2", with_bin: true)
    integration = Dev::Deps::GhIntegration.new(
      repository: Dev::Deps::GhRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir),
    )
    dep = Dev::Deps::Dependency.new(name: "MsvcWineToolchain", integration: :gh, group: :build,
      version: "toolchain-2", hash: nil,
      metadata: { "repo" => "d3mlabs/unreal-engine-build-base", "asset_pattern" => "*.tar.zst.*", "assets" => [] })

    When "installing"
    integration.install_all([dep])

    Then
    0 * Dev::ShadowenvPath.setup!
    true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all activates what installed before raising for what did not" do
    Given "two trees, one published with a bin, the other failing to install"
    dir = Dir.mktmpdir("dev-gh-int-test-")
    project = File.join(dir, "project")
    FileUtils.mkdir_p(project)
    version_dir = publish_tree(dir, repo: "d3mlabs/unreal-engine-build-base", tag: "toolchain-2", with_bin: true)
    integration = ExplodingGhIntegration.new(
      fail_names: ["UnrealEngine"],
      repository: Dev::Deps::GhRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir), project_root: project,
    )
    deps = [
      Dev::Deps::Dependency.new(name: "UnrealEngine", integration: :gh, group: :build,
        version: "5.6.1-css-83", hash: nil, metadata: { "repo" => "satisfactorymodding/UnrealEngine" }),
      Dev::Deps::Dependency.new(name: "MsvcWineToolchain", integration: :gh, group: :build,
        version: "toolchain-2", hash: nil, metadata: { "repo" => "d3mlabs/unreal-engine-build-base" }),
    ]

    When "installing all"
    error = assert_raises(Dev::Deps::Integration::PartialInstallError) { integration.install_all(deps) }

    Then "the toolchain is on PATH, the engine is in neither the provide nor the error's absence"
    _ * Kernel.system >> true
    gh_lisp(project).include?("#{version_dir}/bin")
    gh_lisp(project).include?('(provide "gh" "MsvcWineToolchain@toolchain-2")')
    !gh_lisp(project).include?("UnrealEngine")
    error.failures.map(&:first) == ["UnrealEngine"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all attempts the remaining deps when one fails, then raises the aggregate" do
    Given "two gh dependencies, the first of which fails to install"
    dir = Dir.mktmpdir("dev-gh-int-test-")
    integration = ExplodingGhIntegration.new(
      fail_names: ["UnrealEngine"],
      repository: Dev::Deps::GhRepository.new,
      store: Dev::Deps::LocalStore.new(data_root: dir),
    )
    deps = [
      Dev::Deps::Dependency.new(name: "UnrealEngine", integration: :gh, group: :build,
        version: "5.6.1-css-83", hash: nil, metadata: {}),
      Dev::Deps::Dependency.new(name: "OtherTool", integration: :gh, group: :build,
        version: "1.0.0", hash: nil, metadata: {}),
    ]

    When "installing all and capturing the aggregate error"
    error = nil
    begin
      integration.install_all(deps)
    rescue StandardError => e
      error = e
    end

    Then "the second dep was still attempted and the aggregate lists only the first"
    integration.attempted == ["UnrealEngine", "OtherTool"]
    error.is_a?(Dev::Deps::Integration::PartialInstallError)
    error.failures.map(&:first) == ["UnrealEngine"]

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

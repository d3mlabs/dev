# typed: false
# frozen_string_literal: true

require "test_helper"
require "support/recording_ui"
require "dev/deps/egs_integration"
require "dev/deps/build_patch_tool"
require "dev/deps/local_store"
require "dev/deps/dependency"
require "dev/deps/url_repository"
require "digest"
require "fileutils"
require "pathname"
require "tmpdir"

# EgsIntegration with the curl boundary replaced by copying a zip built in
# the test. Verification, extraction, the marker and publishing run for
# real against the filesystem.
class FixtureEgsIntegration < Dev::Deps::EgsIntegration
  attr_reader :download_count

  def initialize(zip:, **kwargs)
    super(**kwargs)
    @zip = zip
    @download_count = 0
  end

  private

  def download(_dep, archive)
    @download_count += 1
    FileUtils.cp(@zip, archive)
  end
end unless defined?(FixtureEgsIntegration)

transform!(RSpock::AST::Transformation)
class Dev::Deps::EgsIntegrationTest < Minitest::Test
  URL = Dev::Deps::BuildPatchTool::DOWNLOAD_URL

  def setup
    @root = Pathname(Dir.mktmpdir("egs-integration-"))
    @data_root = @root / "data"
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  # A zip in the tool's layout, every platform's binary present.
  def tool_zip
    tree = @root / "zip-src"
    Dev::Deps::BuildPatchTool::BINARIES.each_value do |relative|
      (tree / relative).dirname.mkpath
      (tree / relative).write("#!/bin/sh\necho #{relative}\n")
    end
    zip = @root / "BuildPatchTool.zip"
    system("zip", "-q", "-r", zip.to_s, ".", chdir: tree.to_s) || raise("fixture zip failed")
    zip
  end

  def dependency(digest)
    Dev::Deps::Dependency.new(
      name: "BuildPatchTool", integration: :egs, group: :default, version: nil, hash: digest,
      metadata: { "url" => URL },
    )
  end

  def digest_of(path)
    "SHA256=#{Digest::SHA256.file(path).hexdigest}"
  end

  def integration(zip, ui: RecordingUi.new)
    FixtureEgsIntegration.new(zip:, repository: Dev::Deps::UrlRepository.new, store: Dev::Deps::LocalStore.new(data_root: @data_root.to_s), ui: ui)
  end

  test "the install speaks through the Ui (dev#573): a step per child handed the terminal, then the fact; a second pass is the fact alone" do
    Given "a tool zip and the dep locked to its digest, over a recording Ui"
    zip = tool_zip
    dep = dependency(digest_of(zip))
    ui = RecordingUi.new
    integration = integration(zip, ui: ui)
    tree = @data_root / "egs/BuildPatchTool" / dep.hash

    When "installing twice"
    integration.install_all([dep])
    integration.install_all([dep])

    Then
    ui.rows == [
      [:step, "Downloading BuildPatchTool from #{URL}", 0],
      [:step, "Extracting BuildPatchTool", 0],
      [:note, "{{v}} BuildPatchTool installed at #{tree}", 0],
      [:note, "{{v}} BuildPatchTool is installed at #{tree}", 0],
    ]
  end

  test "tree_key places the tool by identity and digest: ~/.dev/egs/<name>/<digest>" do
    When
    key = Dev::Deps::EgsIntegration.tree_key(dependency("SHA256=abc"))

    Then
    [key.base, key.version, key.marker, key.platform] == ["~/.dev/egs/BuildPatchTool", "SHA256=abc", Dev::Deps::EgsIntegration::MARKER_FILE, nil]
  end

  test "tree_key refuses a pin locked without a digest" do
    When
    Dev::Deps::EgsIntegration.tree_key(dependency(nil))

    Then
    error = raises Dev::Deps::EgsIntegration::MissingDigestError
    error.message == "BuildPatchTool: #{URL} is locked without a digest — run dev deps update"
  end

  test "install_all downloads the zip, verifies it against the lock, unpacks it into the digest-keyed tree with executable binaries, and is idempotent" do
    Given "a tool zip and the dep locked to its digest"
    zip = tool_zip
    dep = dependency(digest_of(zip))
    integration = integration(zip)

    When "installing twice"
    integration.install_all([dep])
    integration.install_all([dep])

    Then "the tree holds the zip's layout, the binaries are executable, and the second pass skipped the download"
    tree = @data_root / "egs/BuildPatchTool" / dep.hash
    (tree / Dev::Deps::EgsIntegration::MARKER_FILE).file?
    (tree / "Engine/Binaries/Mac/BuildPatchTool").executable?
    (tree / "Engine/Binaries/Linux/BuildPatchTool").executable?
    (tree / "Engine/Binaries/Win64/BuildPatchTool.exe").read == "#!/bin/sh\necho Engine/Binaries/Win64/BuildPatchTool.exe\n"
    !(tree / "BuildPatchTool.zip").exist?
    integration.download_count == 1
    Dev::Deps::BuildPatchTool.binary(tree, host: "darwin") == tree / "Engine/Binaries/Mac/BuildPatchTool"
  end

  test "a download that is not what the lock recorded is refused and leaves no tree" do
    Given "the dep locked to another digest"
    zip = tool_zip
    dep = dependency("SHA256=#{"0" * 64}")

    When
    integration(zip).install_all([dep])

    Then
    error = raises Dev::Deps::Integration::PartialInstallError
    error.failures.map { |name, failure| [name, failure.class] } == [["BuildPatchTool", Dev::Deps::EgsIntegration::IntegrityError]]
    error.failures[0][1].message == "BuildPatchTool: digest mismatch — the lock says SHA256=#{"0" * 64}, the download is #{digest_of(zip)}; run dev deps update"
    !(@data_root / "egs/BuildPatchTool" / dep.hash).exist?
  end

  test "a download that is no zip fails extraction" do
    Given "a file that is not a zip, locked honestly"
    bogus = @root / "bogus.zip"
    bogus.write("not a zip")
    dep = dependency(digest_of(bogus))

    When
    integration(bogus).install_all([dep])

    Then
    error = raises Dev::Deps::Integration::PartialInstallError
    error.failures[0][1].is_a?(Dev::Deps::EgsIntegration::ExtractionError)
  end

  test "a failing curl is a DownloadError" do
    Given "a dep whose url nothing serves"
    dep = Dev::Deps::Dependency.new(
      name: "BuildPatchTool", integration: :egs, group: :default, version: nil, hash: "SHA256=abc",
      metadata: { "url" => "file://#{@root}/absent.zip" },
    )
    integration = Dev::Deps::EgsIntegration.new(repository: Dev::Deps::UrlRepository.new, store: Dev::Deps::LocalStore.new(data_root: @data_root.to_s))

    When
    integration.install_all([dep])

    Then
    error = raises Dev::Deps::Integration::PartialInstallError
    error.failures[0][1].is_a?(Dev::Deps::EgsIntegration::DownloadError)
  end
end

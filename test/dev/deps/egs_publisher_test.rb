# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/egs_publisher"
require "dev/deps/dependency"
require "dev/deps/local_store"
require "dev/deps/lockfile"
require "dev/lifecycle"
require "support/lifecycle_fixtures"
require "fileutils"
require "pathname"
require "time"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::EgsPublisherTest < Minitest::Test
  include LifecycleFixtures

  NOON = Time.utc(2026, 11, 4, 12, 0, 0)
  DIGEST = "SHA256=#{"ab" * 32}".freeze
  OPTIONS = {
    "organization" => "o-abc",
    "product" => "p-def",
    "artifacts" => {
      "cellbound-3d-win64" => { "id" => "a-win", "launch" => "Cellbound3D.exe", "args" => "-nosplash" },
      "cellbound-3d-linux64" => { "id" => "a-linux", "launch" => "Cellbound3D.sh" },
    },
  }.freeze

  def setup
    @root = Pathname(Dir.mktmpdir("egs-publish-"))
    @project = @root / "project"
    @project.mkpath
    @data_root = @root / "data"
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  # Lock the tool and, unless told otherwise, install a fake of it: a shell
  # script that records its argv and the secret's variable, then exits as told.
  def tool(installed: true, exit_with: 0)
    dep = Dev::Deps::Dependency.new(
      name: "BuildPatchTool", integration: :egs, group: :default, version: nil, hash: DIGEST,
      metadata: { "url" => Dev::Deps::BuildPatchTool::DOWNLOAD_URL },
    )
    Dev::Deps::Lockfile.new(dir: @project).lock([dep])
    return unless installed

    tree = @data_root / "egs/BuildPatchTool" / DIGEST
    binary = tree / "Engine/Binaries/Mac/BuildPatchTool"
    binary.dirname.mkpath
    binary.write(<<~SH)
      #!/bin/sh
      printf '%s\\n' "$*" "secret=${DEV_EGS_CLIENT_SECRET:-unset}" --- >> "#{@root}/calls"
      echo "BuildPatchTool said no" >&2
      exit #{exit_with}
    SH
    binary.chmod(0o755)
    (tree / Dev::Deps::EgsIntegration::MARKER_FILE).write(DIGEST)
  end

  def calls
    (@root / "calls").read.split("---\n").map { |call| call.lines.map(&:chomp) }
  end

  def shipment(build_name)
    install = @root / "installs" / build_name
    install.mkpath
    (install / "#{build_name}.bin").write(build_name)
    dir = @root / "store" / build_name
    packed = Dev::Lifecycle::Archive.new.package(build(build_name), install, dir / build_name)
    manifest = Dev::Lifecycle::Manifest::Artifact.new(
      stamp: Dev::Lifecycle::Manifest::Stamp.now(dev_version: "0.7.2", now: NOON),
      build: build(build_name),
      state: Dev::Lifecycle::GitState.new(sha: "3f2a1c9d8e7b", dirty: false),
      packaged_at: NOON,
      builder: "script",
      builder_version: nil,
      build_id: Dev::Lifecycle::BuildId.new("1.2.0+3f2a1c9d8e7b"),
      archive: packed.name,
      archive_sha256: "ab" * 32,
    )
    Dev::Lifecycle::Shipment.of_artifact(Dev::Lifecycle::Artifact.new(dir:, manifest:))
  end

  def channel(options = OPTIONS)
    Dev::Lifecycle::Channel.new(
      name: "egs", accepts: [Dev::Lifecycle::BuildPattern.parse("cellbound-3d", all_targets)],
      publisher: Dev::Lifecycle::PublisherSpec::Integration.new(name: "egs"), options:,
    )
  end

  def credentials
    Dev::Credentials.stubs(:resolve).with(has_entries(namespace: "egs", key: "client_id", env_var: "EGS_CLIENT_ID")).returns("xyz-client")
    Dev::Credentials.stubs(:resolve).with(has_entries(namespace: "egs", key: "client_secret", env_var: "EGS_CLIENT_SECRET")).returns("s3cret")
  end

  def publisher
    Dev::Deps::EgsPublisher.new(project_root: @project, store: Dev::Deps::LocalStore.new(data_root: @data_root.to_s), host: "darwin")
  end

  test "publish unpacks each archive into a build root, registers it as a binary of its artifact with the secret in the environment, then labels it for the track" do
    Given "the tool installed, credentials stored, a win64 shipment on the live track"
    tool
    credentials
    scratch = @root / "store/.egs"

    When
    receipt = publisher.publish([shipment("cellbound-3d-win64-release")], channel: channel, track: Dev::Lifecycle::Track::Live, scratch:)

    Then
    receipt == Dev::Lifecycle::Receipt.new(summary: "egs 1.2.0+3f2a1c9d8e7b → artifact a-win labelled Live")
    (scratch / "builds/cellbound-3d-win64-release/cellbound-3d-win64-release.bin").read == "cellbound-3d-win64-release"
    (scratch / "cloud/a-win").directory?
    calls == [
      [
        "-OrganizationId=o-abc -ProductId=p-def -ArtifactId=a-win -ClientId=xyz-client -ClientSecretEnvVar=DEV_EGS_CLIENT_SECRET " \
          "-BuildVersion=1.2.0+3f2a1c9d8e7b -mode=UploadBinary -BuildRoot=#{scratch}/builds/cellbound-3d-win64-release " \
          "-CloudDir=#{scratch}/cloud/a-win -AppLaunch=Cellbound3D.exe -AppArgs=-nosplash",
        "secret=s3cret",
      ],
      [
        "-OrganizationId=o-abc -ProductId=p-def -ArtifactId=a-win -ClientId=xyz-client -ClientSecretEnvVar=DEV_EGS_CLIENT_SECRET " \
          "-BuildVersion=1.2.0+3f2a1c9d8e7b -mode=LabelBinary -Label=Live -Platform=Windows",
        "secret=s3cret",
      ],
    ]
  end

  test "a testing deploy takes the testing label" do
    Given
    tool
    credentials

    When
    receipt = publisher.publish(
      [shipment("cellbound-3d-win64-dev")], channel: channel(OPTIONS.merge("labels" => { "testing" => "QA" })),
      track: Dev::Lifecycle::Track::Testing, scratch: @root / "store/.egs",
    )

    Then
    receipt.summary == "egs 1.2.0+3f2a1c9d8e7b → artifact a-win labelled QA"
    calls.last[0].end_with?("-mode=LabelBinary -Label=QA -Platform=Windows")
  end

  test "a build for a platform the store does not serve is refused before anything runs" do
    Given "the tool installed and a linux64 shipment"
    tool
    credentials

    When
    publisher.publish([shipment("cellbound-3d-linux64-release")], channel: channel, track: Dev::Lifecycle::Track::Live, scratch: @root / "store/.egs")

    Then
    error = raises Dev::Deps::EgsPublisher::UnsupportedPlatformError
    error.message == "cellbound-3d-linux64-release: the Epic Games Store serves win64 and macos builds, not linux64 — narrow the channel's `targets:`"
    !(@root / "calls").exist?
    !(@root / "store/.egs").exist?
  end

  test "a build with no platform axis is refused too: the store labels a binary by platform" do
    Given "a channel accepting the gem"
    tool
    credentials
    gem_channel = Dev::Lifecycle::Channel.new(
      name: "egs", accepts: [Dev::Lifecycle::BuildPattern.parse("rspock", all_targets)],
      publisher: Dev::Lifecycle::PublisherSpec::Integration.new(name: "egs"),
      options: OPTIONS.merge("artifacts" => { "rspock" => { "id" => "a-gem", "launch" => "rspock" } }),
    )

    When
    publisher.publish([shipment("rspock")], channel: gem_channel, track: Dev::Lifecycle::Track::Live, scratch: @root / "store/.egs")

    Then
    error = raises Dev::Deps::EgsPublisher::UnsupportedPlatformError
    error.message == "rspock: the Epic Games Store serves win64 and macos builds, not a build with no platform — narrow the channel's `targets:`"
  end

  test "without the tool in the lock the channel was wired by mistake" do
    When
    publisher.publish([shipment("cellbound-3d-win64-release")], channel: channel, track: Dev::Lifecycle::Track::Live, scratch: @root / "store/.egs")

    Then
    error = raises Dev::Deps::EgsPublisher::NoToolPinnedError
    error.message == "the lock pins no egs dependency — declare `egs \"BuildPatchTool\"` in dependencies.rb"
  end

  test "with the tool locked but not installed the fix is dev up" do
    Given
    tool(installed: false)

    When
    publisher.publish([shipment("cellbound-3d-win64-release")], channel: channel, track: Dev::Lifecycle::Track::Live, scratch: @root / "store/.egs")

    Then
    error = raises Dev::Deps::EgsPublisher::ToolNotInstalledError
    error.message == "BuildPatchTool is not installed at #{@data_root}/egs/BuildPatchTool/#{DIGEST} — run dev up"
  end

  test "a failing tool is an UploadFailedError naming the step and carrying the tool's last lines" do
    Given
    tool(exit_with: 3)
    credentials

    When
    publisher.publish([shipment("cellbound-3d-win64-release")], channel: channel, track: Dev::Lifecycle::Track::Live, scratch: @root / "store/.egs")

    Then
    error = raises Dev::Deps::EgsPublisher::UploadFailedError
    error.message == "BuildPatchTool upload of cellbound-3d-win64-release (1.2.0+3f2a1c9d8e7b) exited 3: BuildPatchTool said no"
    calls.size == 1
  end

  test "the options are checked before the tool or the credentials are looked up" do
    Given "a channel missing its product"
    Dev::Credentials.expects(:resolve).never

    When
    publisher.publish([shipment("cellbound-3d-win64-release")], channel: channel(OPTIONS.except("product")), track: Dev::Lifecycle::Track::Live, scratch: @root / "store/.egs")

    Then
    raises Dev::Deps::EgsChannelOptions::MissingOptionError
  end
end

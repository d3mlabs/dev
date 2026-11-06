# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "support/lifecycle_fixtures"
require "fileutils"
require "pathname"
require "time"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::ScriptPublisherTest < Minitest::Test
  include LifecycleFixtures

  NOON = Time.utc(2026, 11, 4, 12, 0, 0)

  def setup
    @root = Pathname(Dir.mktmpdir("script-publisher-"))
    @project = @root / "project"
    @project.mkpath
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  def artifact(build_name)
    dir = @root / "store" / build_name
    dir.mkpath
    (dir / "#{build_name}.zip").write("zip")
    manifest = Dev::Lifecycle::Manifest::Artifact.new(
      stamp: Dev::Lifecycle::Manifest::Stamp.now(dev_version: "0.7.2", now: NOON),
      build: build(build_name),
      state: Dev::Lifecycle::GitState.new(sha: "3f2a1c9d8e7b", dirty: false),
      packaged_at: NOON,
      builder: "script",
      builder_version: nil,
      build_id: Dev::Lifecycle::BuildId.new("1.2.0+3f2a1c9d8e7b"),
      archive: "#{build_name}.zip",
      archive_sha256: "ab" * 32,
    )
    Dev::Lifecycle::Artifact.new(dir:, manifest:)
  end

  def channel(command)
    Dev::Lifecycle::Channel.new(
      name: "steam", desc: "Steam", accepts: [Dev::Lifecycle::BuildPattern.parse("cellbound-3d", all_targets)],
      publisher: Dev::Lifecycle::PublisherSpec::Script.new(command:),
    )
  end

  test "the run: line runs at the project root once per artifact, in order, with each archive, the track, the scratch and its manifest in the env" do
    Given "a script that appends what it was handed, and a scratch not yet created"
    (@project / "stage.sh").write(<<~SH)
      #!/bin/sh
      set -eu
      echo "$(pwd) $DEV_CHANNEL $DEV_TRACK $DEV_BUILD $DEV_CONFIG $DEV_BUILD_ID $DEV_SHA $DEV_DIRTY ${DEV_INSTALL:-unset}" >> "#{@root}/shipped"
      echo "$DEV_ARTIFACT" >> "#{@root}/shipped"
      test -d "$DEV_SCRATCH" && echo "$DEV_SCRATCH" >> "#{@root}/shipped"
    SH
    publisher = Dev::Lifecycle::ScriptPublisher.new(command: "sh ./stage.sh", project_root: @project)
    win64 = artifact("cellbound-3d-win64-dev")
    linux64 = artifact("cellbound-3d-linux64-dev")
    scratch = @root / "store" / ".steam"

    When
    publisher.publish([win64, linux64], channel: channel("sh ./stage.sh"), track: Dev::Lifecycle::Track::Live, scratch:)

    Then "the scratch exists before the first run"
    (@root / "shipped").read.lines.map(&:chomp) == [
      "#{@project.realpath} steam live cellbound-3d-win64-dev dev 1.2.0+3f2a1c9d8e7b 3f2a1c9d8e7b false unset",
      win64.archive.to_s,
      scratch.to_s,
      "#{@project.realpath} steam live cellbound-3d-linux64-dev dev 1.2.0+3f2a1c9d8e7b 3f2a1c9d8e7b false unset",
      linux64.archive.to_s,
      scratch.to_s,
    ]
    publisher.command == "sh ./stage.sh"
    publisher.to_s == "sh ./stage.sh"
  end

  test "the first archive the script fails on ends the deploy, named with the exit code; the ones before it shipped" do
    Given "a script that refuses the linux64 archive"
    (@project / "stage.sh").write(<<~SH)
      #!/bin/sh
      case "$DEV_PLATFORM" in
        win64) echo "$DEV_BUILD" >> "#{@root}/shipped" ;;
        *) exit 3 ;;
      esac
    SH
    publisher = Dev::Lifecycle::ScriptPublisher.new(command: "sh ./stage.sh", project_root: @project)

    When
    publisher.publish([artifact("cellbound-3d-win64-dev"), artifact("cellbound-3d-linux64-dev"), artifact("cellbound-3d-win64-release")],
      channel: channel("sh ./stage.sh"), track: Dev::Lifecycle::Track::Testing, scratch: @root / "store" / ".steam")

    Then
    error = raises Dev::Lifecycle::ScriptPublisher::DeployScriptFailedError
    error.message == "deploy script `sh ./stage.sh` for cellbound-3d-linux64-dev → steam exited 3"
    (@root / "shipped").read == "cellbound-3d-win64-dev\n"
  end

  test "a project root that does not exist is a spawn failure, not a script one" do
    When
    Dev::Lifecycle::ScriptPublisher.new(command: "true", project_root: @root / "missing")
      .publish([artifact("rspock")], channel: channel("true"), track: Dev::Lifecycle::Track::Testing, scratch: @root / "store" / ".steam")

    Then
    raises Dev::Lifecycle::Shell::SpawnError
  end
end

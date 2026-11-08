# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "support/lifecycle_fixtures"
require "pathname"
require "time"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::ScriptEnvTest < Minitest::Test
  include LifecycleFixtures

  test "a channel's run: sees the artifact's axes, the archive file, the channel, the track, the scratch and the manifest's keys" do
    Given "an artifact packaged from a clean tree"
    manifest = Dev::Lifecycle::Manifest::Artifact.new(
      stamp: Dev::Lifecycle::Manifest::Stamp.now(dev_version: "0.7.2", now: Time.utc(2026, 11, 4, 12, 0, 0)),
      build: build("cellbound-3d-win64-dev"),
      state: Dev::Lifecycle::GitState.new(sha: "3f2a1c9d8e7b", dirty: false),
      packaged_at: Time.utc(2026, 11, 4, 12, 30, 0),
      builder: "script",
      builder_version: nil,
      build_id: Dev::Lifecycle::BuildId.new("1.2.0+3f2a1c9d8e7b"),
      archive: "cellbound-3d-win64-dev.zip",
      archive_sha256: "ab" * 32,
    )
    shipment = Dev::Lifecycle::Shipment.of_artifact(Dev::Lifecycle::Artifact.new(dir: Pathname("/data/artifacts/cellbound-3d/cellbound-3d-win64-dev"), manifest:))

    Expect
    Dev::Lifecycle::ScriptEnv.for_deploy(
      shipment, channel: "staging", track: Dev::Lifecycle::Track::Testing, scratch: Pathname("/data/artifacts/cellbound-3d/.staging"),
    ) == {
      "DEV_TARGET" => "cellbound-3d",
      "DEV_PLATFORM" => "win64",
      "DEV_CONFIG" => "dev",
      "DEV_ARTIFACT" => "/data/artifacts/cellbound-3d/cellbound-3d-win64-dev/cellbound-3d-win64-dev.zip",
      "DEV_CHANNEL" => "staging",
      "DEV_TRACK" => "testing",
      "DEV_SCRATCH" => "/data/artifacts/cellbound-3d/.staging",
      "DEV_BUILD" => "cellbound-3d-win64-dev",
      "DEV_BUILD_ID" => "1.2.0+3f2a1c9d8e7b",
      "DEV_SHA" => "3f2a1c9d8e7b",
      "DEV_DIRTY" => "false",
      "DEV_PACKAGED_AT" => "2026-11-04T12:30:00Z",
      "DEV_ARCHIVE_SHA256" => "ab" * 32,
    }
  end

  test "an artifact packaged outside a checkout ships with DEV_SHA unknown and DEV_DIRTY true" do
    Given
    manifest = Dev::Lifecycle::Manifest::Artifact.new(
      stamp: Dev::Lifecycle::Manifest::Stamp.now(dev_version: "0.7.2", now: Time.utc(2026, 11, 4)),
      build: build("rspock"),
      state: Dev::Lifecycle::GitState.new(sha: nil, dirty: true),
      packaged_at: Time.utc(2026, 11, 4),
      builder: "none",
      builder_version: nil,
      build_id: Dev::Lifecycle::BuildId.new("1.2.0+unknown.20261104T000000Z"),
      archive: "rspock.gem",
      archive_sha256: "cd" * 32,
    )
    env = Dev::Lifecycle::ScriptEnv.for_deploy(
      Dev::Lifecycle::Shipment.of_artifact(Dev::Lifecycle::Artifact.new(dir: Pathname("/store/rspock"), manifest:)),
      channel: "rubygems", track: Dev::Lifecycle::Track::Testing, scratch: Pathname("/store/.rubygems"),
    )

    Expect
    env.slice("DEV_SHA", "DEV_DIRTY", "DEV_ARTIFACT", "DEV_TRACK") ==
      { "DEV_SHA" => "unknown", "DEV_DIRTY" => "true", "DEV_ARTIFACT" => "/store/rspock/rspock.gem", "DEV_TRACK" => "testing" }
    !env.key?("DEV_PLATFORM")
    !env.key?("DEV_INSTALL")
    !env.key?("DEV_RELEASE_VERSION")
  end

  test "a release's archive ships with DEV_RELEASE_VERSION and the tag's commit as DEV_SHA, and none of the store's keys (dev#425)" do
    Given
    entry = Dev::Lifecycle::Manifest::Release::Archive.new(
      build: build("cellbound-3d-win64-release"), name: "cellbound-3d-win64-release-1.2.0.zip", sha256: "cd" * 32,
      build_id: Dev::Lifecycle::BuildId.new("1.2.0+3f2a1c9d8e7b"),
    )
    shipment = Dev::Lifecycle::Shipment.of_release(
      entry, archive: Pathname("/store/.releases/v1.2.0/cellbound-3d-win64-release-1.2.0.zip"),
      tag: Dev::Lifecycle::ReleaseTag.new("1.2.0"), sha: "3f2a1c9d8e7b4455aaaa",
    )

    Expect
    Dev::Lifecycle::ScriptEnv.for_deploy(shipment, channel: "steam", track: Dev::Lifecycle::Track::Live, scratch: Pathname("/store/.steam")) == {
      "DEV_TARGET" => "cellbound-3d",
      "DEV_PLATFORM" => "win64",
      "DEV_CONFIG" => "release",
      "DEV_ARTIFACT" => "/store/.releases/v1.2.0/cellbound-3d-win64-release-1.2.0.zip",
      "DEV_CHANNEL" => "steam",
      "DEV_TRACK" => "live",
      "DEV_SCRATCH" => "/store/.steam",
      "DEV_BUILD" => "cellbound-3d-win64-release",
      "DEV_BUILD_ID" => "1.2.0+3f2a1c9d8e7b",
      "DEV_ARCHIVE_SHA256" => "cd" * 32,
      "DEV_RELEASE_VERSION" => "1.2.0",
      "DEV_SHA" => "3f2a1c9d8e7b",
    }
  end

  test "a build: script sees the build's declared axes and the install directory" do
    Expect
    Dev::Lifecycle::ScriptEnv.for_build(build("cellbound-3d-win64-dev"), install: Pathname("/data/install")) == {
      "DEV_TARGET" => "cellbound-3d",
      "DEV_PLATFORM" => "win64",
      "DEV_CONFIG" => "dev",
      "DEV_INSTALL" => "/data/install",
    }
  end

  test "an axis the target does not declare is absent, not empty" do
    Expect
    Dev::Lifecycle::ScriptEnv.for_build(build("rspock"), install: Pathname("/data/install")) == {
      "DEV_TARGET" => "rspock",
      "DEV_INSTALL" => "/data/install",
    }
  end

  test "a package: script sees the build's env plus the archive path without its extension" do
    Expect
    Dev::Lifecycle::ScriptEnv.for_package(
      build("cellbound-3d-server-linux64-release"),
      install: Pathname("/data/install"),
      archive: Pathname("/data/store/cellbound-3d-server-linux64-release"),
    ) == {
      "DEV_TARGET" => "cellbound-3d-server",
      "DEV_PLATFORM" => "linux64",
      "DEV_CONFIG" => "release",
      "DEV_INSTALL" => "/data/install",
      "DEV_ARTIFACT" => "/data/store/cellbound-3d-server-linux64-release",
    }
  end
end

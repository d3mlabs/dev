# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "support/lifecycle_fixtures"
require "pathname"
require "time"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::DeploymentRecordTest < Minitest::Test
  include LifecycleFixtures

  RECORD = Dev::Lifecycle::DeploymentRecord
  STATE = Dev::Lifecycle::DeploymentState
  TRACK = Dev::Lifecycle::Track
  NOON = Time.utc(2026, 11, 5, 12, 0, 0)

  def artifact(build_name, sha: "3f2a1c9d8e7b", dirty: false)
    state = Dev::Lifecycle::GitState.new(sha:, dirty:)
    manifest = Dev::Lifecycle::Manifest::Artifact.new(
      stamp: Dev::Lifecycle::Manifest::Stamp.now(dev_version: "0.7.6", now: NOON),
      build: build(build_name), state:, packaged_at: NOON, builder: "script", builder_version: nil,
      build_id: Dev::Lifecycle::BuildId.derive(state:, semver: "1.2.0", now: NOON),
      archive: "#{build_name}.zip", archive_sha256: "ab" * 32,
    )
    Dev::Lifecycle::Shipment.of_artifact(Dev::Lifecycle::Artifact.new(dir: Pathname("/store") / build_name, manifest:))
  end

  def released(build_name, version: "1.2.0")
    entry = Dev::Lifecycle::Manifest::Release::Archive.new(
      build: build(build_name), name: "#{build_name}-#{version}.zip", sha256: "cd" * 32, build_id: Dev::Lifecycle::BuildId.new("#{version}+3f2a1c9d8e7b"),
    )
    Dev::Lifecycle::Shipment.of_release(entry, archive: Pathname("/store/.releases/v#{version}") / entry.name, tag: Dev::Lifecycle::ReleaseTag.new(version), sha: "3f2a1c9d8e7b4455")
  end

  def shipped(name, build_id) = RECORD::DeployedBuild.new(name:, build_id: Dev::Lifecycle::BuildId.new(build_id))

  test "one deploy of artifacts from one commit is one record: the channel, that commit as the ref, the builds with their ids, in order" do
    Given
    artifacts = [artifact("cellbound-3d-win64-dev"), artifact("cellbound-3d-linux64-dev")]

    When
    records = RECORD.of(artifacts, channel: "staging", track: TRACK::Testing, state: STATE::Success, description: "run: ./bin/stage")

    Then
    records == [
      RECORD.new(
        channel: "staging", ref: "3f2a1c9d8e7b", track: TRACK::Testing, state: STATE::Success, description: "run: ./bin/stage",
        builds: [shipped("cellbound-3d-win64-dev", "1.2.0+3f2a1c9d8e7b"), shipped("cellbound-3d-linux64-dev", "1.2.0+3f2a1c9d8e7b")],
      ),
    ]
    records.first.payload == {
      "schema" => 1,
      "track" => "testing",
      "builds" => [
        { "build" => "cellbound-3d-win64-dev", "build_id" => "1.2.0+3f2a1c9d8e7b" },
        { "build" => "cellbound-3d-linux64-dev", "build_id" => "1.2.0+3f2a1c9d8e7b" },
      ],
    }
    records.first.builds.first.to_s == "cellbound-3d-win64-dev (1.2.0+3f2a1c9d8e7b)"
  end

  test "artifacts of different commits shipped together (--allow-stale) are one record per commit, since a GitHub Deployment is one (environment, ref)" do
    Given
    artifacts = [artifact("cellbound-3d-win64-dev"), artifact("rspock", sha: "0123456789ab", dirty: true), artifact("cellbound-3d-linux64-dev")]

    When
    records = RECORD.of(artifacts, channel: "staging", track: TRACK::Testing, state: STATE::Failure, description: "exited 7")

    Then
    records.map(&:ref) == ["3f2a1c9d8e7b", "0123456789ab"]
    records.map { |record| record.builds.map(&:name) } == [["cellbound-3d-win64-dev", "cellbound-3d-linux64-dev"], ["rspock"]]
    records.last.builds.first.build_id.to_s == "1.2.0+0123456789ab.dirty.20261105T120000Z"
    records.all? { |record| record.state == STATE::Failure && record.description == "exited 7" }
  end

  test "an artifact packaged outside a checkout has no commit to record against" do
    When
    RECORD.of([artifact("rspock", sha: nil, dirty: true)], channel: "rubygems", track: TRACK::Testing, state: STATE::Success, description: "x")

    Then
    error = raises RECORD::UnknownRefError
    error.message.include?("rspock (1.2.0+unknown.20261105T120000Z) was packaged outside a checkout")
  end

  test "a release's shipments are one record against the tag, whatever their build: the live deploy `deploy status --release` finds" do
    Given
    shipments = [released("cellbound-3d-win64-release"), released("rspock")]

    When
    records = RECORD.of(shipments, channel: "steam", track: TRACK::Live, state: STATE::Success, description: "pushed")

    Then
    records.map(&:ref) == ["v1.2.0"]
    records.first.builds == [shipped("cellbound-3d-win64-release", "1.2.0+3f2a1c9d8e7b"), shipped("rspock", "1.2.0+3f2a1c9d8e7b")]
    records.first.track == TRACK::Live
  end

  test "a payload dev wrote reads back as the record it came from, with the status the forge holds" do
    Given
    written = RECORD.of([artifact("rspock")], channel: "rubygems", track: TRACK::Live, state: STATE::Success, description: "gem push").first

    When
    read = RECORD.from_payload(written.payload, channel: "rubygems", ref: "v1.2.0", state: STATE::Success, description: "gem push")

    Then
    read == RECORD.new(
      channel: "rubygems", ref: "v1.2.0", track: TRACK::Live, state: STATE::Success, description: "gem push",
      builds: [shipped("rspock", "1.2.0+3f2a1c9d8e7b")],
    )
  end

  test "a payload that is not dev's is refused as malformed: #{fault}" do
    When
    RECORD.from_payload(payload, channel: "staging", ref: "abc", state: STATE::Success, description: nil)

    Then
    raises RECORD::MalformedPayloadError

    Where
    fault                 | payload
    "a string"            | "deployed by hand"
    "no track"            | { "builds" => [] }
    "a track off the set" | { "track" => "beta", "builds" => [] }
    "builds not a list"   | { "track" => "testing", "builds" => "rspock" }
    "a build not a hash"  | { "track" => "testing", "builds" => ["rspock"] }
    "a build with no id"  | { "track" => "testing", "builds" => [{ "build" => "rspock" }] }
    "a malformed id"      | { "track" => "testing", "builds" => [{ "build" => "rspock", "build_id" => "1.2.0" }] }
  end
end

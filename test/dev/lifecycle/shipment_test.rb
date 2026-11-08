# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "pathname"
require "support/lifecycle_fixtures"
require "time"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::ShipmentTest < Minitest::Test
  include LifecycleFixtures

  NOON = Time.utc(2026, 11, 4, 12, 0, 0)
  TAG = Dev::Lifecycle::ReleaseTag.new("1.2.0")

  def manifest(state:)
    Dev::Lifecycle::Manifest::Artifact.new(
      stamp: Dev::Lifecycle::Manifest::Stamp.now(dev_version: "0.7.2", now: NOON),
      build: build("rspock"), state:, packaged_at: NOON, builder: "script", builder_version: nil,
      build_id: Dev::Lifecycle::BuildId.new("1.2.0+3f2a1c9d8e7b"), archive: "rspock.gem", archive_sha256: "ab" * 32,
    )
  end

  def entry
    Dev::Lifecycle::Manifest::Release::Archive.new(
      build: build("rspock"), name: "rspock-1.2.0.gem", sha256: "cd" * 32, build_id: Dev::Lifecycle::BuildId.new("1.2.0+3f2a1c9d8e7b"),
    )
  end

  test "of_artifact carries the store's artifact: its archive, build, id and digest, with the tree it was packaged from as provenance" do
    Given
    state = Dev::Lifecycle::GitState.new(sha: "3f2a1c9d8e7b", dirty: false)
    artifact = Dev::Lifecycle::Artifact.new(dir: Pathname("/store/rspock"), manifest: manifest(state:))

    When
    shipment = Dev::Lifecycle::Shipment.of_artifact(artifact)

    Then
    shipment.archive == Pathname("/store/rspock/rspock.gem")
    shipment.name == "rspock"
    shipment.build_id == Dev::Lifecycle::BuildId.new("1.2.0+3f2a1c9d8e7b")
    shipment.archive_sha256 == "ab" * 32
    shipment.provenance == Dev::Lifecycle::Provenance::Store.new(state:, packaged_at: NOON)
    shipment.ref == "3f2a1c9d8e7b"
    shipment.to_s == "rspock (1.2.0+3f2a1c9d8e7b)"
  end

  test "an artifact packaged outside a checkout has no ref to record against" do
    Given
    artifact = Dev::Lifecycle::Artifact.new(dir: Pathname("/store/rspock"), manifest: manifest(state: Dev::Lifecycle::GitState.new(sha: nil, dirty: true)))

    Expect
    Dev::Lifecycle::Shipment.of_artifact(artifact).ref.nil?
  end

  test "of_release carries a release's archive as release.json lists it, with the tag as provenance and ref" do
    When
    shipment = Dev::Lifecycle::Shipment.of_release(entry, archive: Pathname("/store/.releases/v1.2.0/rspock-1.2.0.gem"), tag: TAG, sha: "3f2a1c9d8e7b0000")

    Then
    shipment.archive == Pathname("/store/.releases/v1.2.0/rspock-1.2.0.gem")
    shipment.name == "rspock"
    shipment.build_id == Dev::Lifecycle::BuildId.new("1.2.0+3f2a1c9d8e7b")
    shipment.archive_sha256 == "cd" * 32
    shipment.provenance == Dev::Lifecycle::Provenance::Release.new(tag: TAG, sha: "3f2a1c9d8e7b0000")
    shipment.ref == "v1.2.0"
  end

  test "shipments and provenances are values: equal by content, usable as hash keys" do
    Given
    a = Dev::Lifecycle::Shipment.of_release(entry, archive: Pathname("/a"), tag: TAG, sha: "abc")
    b = Dev::Lifecycle::Shipment.of_release(entry, archive: Pathname("/a"), tag: TAG, sha: "abc")
    other = Dev::Lifecycle::Shipment.of_release(entry, archive: Pathname("/a"), tag: Dev::Lifecycle::ReleaseTag.new("1.3.0"), sha: "abc")

    Expect
    a == b
    a.eql?(b)
    a.hash == b.hash
    a != other
    { a => 1 }.key?(b)
    Dev::Lifecycle::Provenance::Store.new(state: Dev::Lifecycle::GitState.new(sha: "x", dirty: false), packaged_at: NOON) !=
      Dev::Lifecycle::Provenance::Release.new(tag: TAG, sha: "x")
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/skills/manifest"
require "fileutils"
require "json"
require "pathname"
require "time"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Skills::ManifestTest < Minitest::Test
  def record(integration, link, **extra)
    Dev::Skills::Manifest::Record.new(
      name: File.basename(link), integration: integration, link: link, source: "/src/#{link}", **extra,
    )
  end

  test "write then read round-trips the records, sorted by integration and link" do
    Given "a manifest with two channels' records"
    dir = Dir.mktmpdir("dev-skills-manifest-test-")
    root = File.join(dir, "root")
    manifest = Dev::Skills::Manifest.new(root: root, records: [
      record("gem", "gem/rspock/rspock", package: "rspock", version: "3.0.0"),
      record("dev", "ai-flow"),
    ])

    When "writing and reading back"
    manifest.write(now: Time.utc(2026, 10, 8, 12, 0, 0))
    read = Dev::Skills::Manifest.read(root)

    Then "the file carries the schema, timestamp, and root; the records survive intact"
    raw = JSON.parse(File.read(File.join(root, "manifest.json")))
    raw["schema"] == 1
    raw["generated_at"] == "2026-10-08T12:00:00Z"
    raw["root"] == root
    read.root == Pathname(root)
    read.records.map(&:link) == ["gem/rspock/rspock", "ai-flow"]
    read.for_integration("gem")[0].package == "rspock"
    read.for_integration("gem")[0].version == "3.0.0"
    read.for_integration("dev")[0].version.nil?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "read of a missing or corrupt manifest is empty" do
    Given "a root with no manifest and one with garbage"
    dir = Dir.mktmpdir("dev-skills-manifest-test-")
    FileUtils.mkdir_p(File.join(dir, "garbage"))
    File.write(File.join(dir, "garbage", "manifest.json"), "[1, 2")

    Expect "both read as empty"
    Dev::Skills::Manifest.read(File.join(dir, "none")).records == []
    Dev::Skills::Manifest.read(File.join(dir, "garbage")).records == []

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "replacing swaps one channel's records and keeps the others'" do
    Given "a manifest with dev and org records"
    manifest = Dev::Skills::Manifest.new(root: "/r", records: [record("dev", "ai-flow"), record("org", "srp")])

    When "replacing org's"
    replaced = manifest.replacing("org", [record("org", "tdd"), record("org", "dry")])

    Then "dev's record stands, org's are the new ones, sorted"
    replaced.records.map { |r| [r.integration, r.link] } == [["dev", "ai-flow"], ["org", "dry"], ["org", "tdd"]]
    manifest.records.size == 2
  end
end

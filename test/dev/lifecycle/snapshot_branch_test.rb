# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "time"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::SnapshotBranchTest < Minitest::Test
  test "mint names the branch after the runner, the UTC instant and the nonce, under dev's namespace" do
    Given
    now = Time.utc(2026, 11, 5, 17, 30, 0)

    When
    branch = Dev::Lifecycle::SnapshotBranch.mint(runner: "cellbound-3d", now:, nonce: "a1b2c3")

    Then
    branch.name == "dev/build/cellbound-3d/20261105T173000Z-a1b2c3"
    branch.ref == "refs/heads/dev/build/cellbound-3d/20261105T173000Z-a1b2c3"
    branch.to_s == branch.name
    branch.runner == "cellbound-3d"
    branch.created_at == now
    branch.nonce == "a1b2c3"
  end

  test "mint without injected values takes the clock and a fresh nonce" do
    When
    branch = Dev::Lifecycle::SnapshotBranch.mint(runner: "ue-engine-hosted")

    Then
    branch.nonce.match?(/\A\h{6}\z/)
    (Time.now - branch.created_at).abs < 5
    Dev::Lifecycle::SnapshotBranch.parse(branch.name) == branch
  end

  test "parse reads a branch back from its short name or its full ref" do
    Expect
    Dev::Lifecycle::SnapshotBranch.parse("dev/build/cellbound-3d/20261105T173000Z-a1b2c3").created_at == Time.utc(2026, 11, 5, 17, 30, 0)
    Dev::Lifecycle::SnapshotBranch.parse("refs/heads/dev/build/cellbound-3d/20261105T173000Z-a1b2c3").runner == "cellbound-3d"
    Dev::Lifecycle::SnapshotBranch.parse("refs/heads/dev/build/cellbound-3d/20261105T173000Z-a1b2c3") ==
      Dev::Lifecycle::SnapshotBranch.mint(runner: "cellbound-3d", now: Time.utc(2026, 11, 5, 17, 30, 0), nonce: "a1b2c3")
  end

  test "a name outside the grammar is malformed: #{name}" do
    When
    Dev::Lifecycle::SnapshotBranch.parse(name)

    Then
    error = raises(Dev::Lifecycle::SnapshotBranch::MalformedSnapshotBranchError)
    error.message.include?(name)
    error.message.include?("dev/build/<runner>/<utc instant>-<nonce>")

    Where
    name
    "main"
    "dev/build/foo"
    "dev/build/cellbound-3d/20261105T173000Z"
    "dev/build/cellbound-3d/20261105T173000Z-xyz"
    "dev/build/a/b/20261105T173000Z-a1b2c3"
    "refs/tags/dev/build/cellbound-3d/20261105T173000Z-a1b2c3"
  end

  test "a runner label that cannot be a ref segment is refused: #{label.inspect}" do
    When
    Dev::Lifecycle::SnapshotBranch.mint(runner: label, nonce: "a1b2c3")

    Then
    error = raises(Dev::Lifecycle::SnapshotBranch::InvalidRunnerLabelError)
    error.message.include?(label.inspect)

    Where
    label
    ""
    "a/b"
    "a b"
    ".hidden"
    "x.lock"
    "a~b"
  end

  test "a nonce outside the grammar is refused" do
    When
    Dev::Lifecycle::SnapshotBranch.new(runner: "r", created_at: Time.now, nonce: "nope")

    Then
    raises(Dev::Lifecycle::SnapshotBranch::MalformedSnapshotBranchError)
  end

  test "older_than? reads the age off the name's instant" do
    Given
    minted = Time.utc(2026, 11, 1, 12, 0, 0)
    branch = Dev::Lifecycle::SnapshotBranch.mint(runner: "r", now: minted, nonce: "000000")
    week = 7 * 24 * 60 * 60

    Expect
    !branch.older_than?(week, now: minted + week)
    branch.older_than?(week, now: minted + week + 1)
    !branch.older_than?(week, now: minted)
  end

  test "branches are values, equal by name, with the instant truncated to the second" do
    Given
    a = Dev::Lifecycle::SnapshotBranch.mint(runner: "r", now: Time.utc(2026, 1, 1, 0, 0, 0.7), nonce: "abcdef")
    b = Dev::Lifecycle::SnapshotBranch.mint(runner: "r", now: Time.utc(2026, 1, 1, 0, 0, 0), nonce: "abcdef")

    Expect
    a == b
    a.eql?(b)
    a.hash == b.hash
    a != Dev::Lifecycle::SnapshotBranch.mint(runner: "r", now: Time.utc(2026, 1, 1), nonce: "abcde0")
    a != Dev::Lifecycle::SnapshotBranch.mint(runner: "s", now: Time.utc(2026, 1, 1), nonce: "abcdef")
    a.frozen?
  end
end

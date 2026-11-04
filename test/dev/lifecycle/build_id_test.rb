# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "time"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::BuildIdTest < Minitest::Test
  NOON = Time.utc(2026, 11, 4, 12, 0, 0)

  test "derive stamps <semver>+<sha> for a clean tree, appending .dirty.<utc> for uncommitted changes and unknown.<utc> outside a checkout" do
    Expect
    Dev::Lifecycle::BuildId.derive(state: state(sha, dirty: dirty), semver: "1.2.0", now: NOON).to_s == expected

    Where
    sha            | dirty | expected
    "3f2a1c9d8e7b" | false | "1.2.0+3f2a1c9d8e7b"
    "3f2a1c9d8e7b" | true  | "1.2.0+3f2a1c9d8e7b.dirty.20261104T120000Z"
    nil            | true  | "1.2.0+unknown.20261104T120000Z"
  end

  test "derive defaults the version for a project without one and renders the instant in UTC" do
    Expect
    Dev::Lifecycle::BuildId.derive(
      state: Dev::Lifecycle::GitState.new(sha: "abc123", dirty: true),
      now: Time.new(2026, 11, 4, 7, 0, 0, "-05:00"),
    ).to_s == "0.0.0+abc123.dirty.20261104T120000Z"
  end

  test "a stamped id reads back as a value" do
    Given
    id = Dev::Lifecycle::BuildId.new("1.2.0+3f2a1c9d8e7b.dirty.20261104T120000Z")

    Expect
    id == Dev::Lifecycle::BuildId.derive(state: state("3f2a1c9d8e7b", dirty: true), semver: "1.2.0", now: NOON)
    id.hash == Dev::Lifecycle::BuildId.new("1.2.0+3f2a1c9d8e7b.dirty.20261104T120000Z").hash
    id != Dev::Lifecycle::BuildId.new("1.2.0+3f2a1c9d8e7b")
    id.frozen?
  end

  test "a string outside the stamp's grammar is refused: #{value.inspect}" do
    When
    Dev::Lifecycle::BuildId.new(value)

    Then
    raises Dev::Lifecycle::BuildId::MalformedBuildIdError

    Where
    value
    ""
    "1.2.0"
    "1.2.0+"
    "+3f2a1c9d8e7b"
    "1.2.0+3f2a1c9d8e7b.dirty"
    "1.2.0+3f2a1c9d8e7b.dirty.noon"
    "1.2.0+unknown"
    "1.2.0+ZZZ"
  end

  private

  def state(sha, dirty: sha.nil?)
    Dev::Lifecycle::GitState.new(sha: sha, dirty: dirty)
  end
end

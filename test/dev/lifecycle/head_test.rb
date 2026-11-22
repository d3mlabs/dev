# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::HeadTest < Minitest::Test
  test "the derived head is the greatest non-prerelease version, in the store's own spelling, whatever the order given" do
    Expect
    Dev::Lifecycle::Head.derive(["1.2.0", "1.10.0", "1.9.3", "2.0.0-rc.1", "1.10.1.pre"]) == "1.10.0"
    Dev::Lifecycle::Head.derive(["1.10.0", "1.2.0"]) == "1.10.0"
    Dev::Lifecycle::Head.derive(["1.0"]) == "1.0"
  end

  test "within a series the head is that major's greatest release — so a 1.x patch deployed after 2.0 is v1's head and leaves the newest alone" do
    Given "a store carrying two series, the older one patched last"
    versions = ["1.0.0", "2.0.0", "1.0.1", "2.1.0-beta.1"]

    Expect
    Dev::Lifecycle::Head.derive(versions, series: Dev::Lifecycle::Series.new(1)) == "1.0.1"
    Dev::Lifecycle::Head.derive(versions, series: Dev::Lifecycle::Series.new(2)) == "2.0.0"
    Dev::Lifecycle::Head.derive(versions) == "2.0.0"
  end

  test "a word that is not a version is not one of the store's versions: a bare-tag universe derives over its version tags alone" do
    Expect
    Dev::Lifecycle::Head.derive(["latest", "toolchain-2", "0.8.13", "0.8.14", "v9.9.9"]) == "0.8.14"
  end

  test "a store with no release has no head: #{versions.inspect}#{" on #{series}" if series}" do
    When
    Dev::Lifecycle::Head.derive(versions, series:)

    Then
    error = raises Dev::Lifecycle::Head::NoHeadError
    error.message == message

    Where
    versions                 | series                          | message
    []                       | nil                             | "no head: the store has no versions"
    ["1.0.0-rc.1", "latest"] | nil                             | "no head: none of the store's versions is a release (1.0.0-rc.1, latest)"
    ["1.0.0", "2.0.0-rc.1"]  | Dev::Lifecycle::Series.new(2)   | "no head on v2: none of the store's versions is a release of that series (1.0.0, 2.0.0-rc.1)"
  end
end

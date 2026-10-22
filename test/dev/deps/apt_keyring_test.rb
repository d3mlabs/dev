# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/apt_keyring"
require "support/openpgp_key_fixture"

transform!(RSpock::AST::Transformation)
class Dev::Deps::AptKeyringTest < Minitest::Test
  BINARY = OpenPGPKeyFixture::BINARY

  def armored = OpenPGPKeyFixture.armored

  test "an armored key bound for a non-.asc path is dearmored, byte for byte" do
    Given "WineHQ's layout: the .sources names a .key path"
    path = "/etc/apt/keyrings/winehq-archive.key"

    When "preparing the fetched (armored) key for that path"
    bytes = Dev::Deps::AptKeyring.content_for(path, armored)

    Then "the binary packet apt reads at any non-.asc extension"
    bytes == BINARY
    bytes.encoding == Encoding::BINARY

    Cleanup
    nil
  end

  test "an armored key bound for a .asc path is written as fetched" do
    Given
    path = "/etc/apt/keyrings/docker.asc"

    When
    bytes = Dev::Deps::AptKeyring.content_for(path, armored)

    Then "apt parses armor at .asc, so the text stays text"
    bytes == armored

    Cleanup
    nil
  end

  test "a binary key bound for a non-.asc path is written as fetched" do
    Given
    path = "/etc/apt/keyrings/vendor.gpg"

    When
    bytes = Dev::Deps::AptKeyring.content_for(path, BINARY)

    Then
    bytes == BINARY

    Cleanup
    nil
  end

  test "a binary key bound for a .asc path is refused: apt would read it as armor and find none" do
    Given
    path = "/etc/apt/keyrings/vendor.asc"

    When
    error = assert_raises(Dev::Deps::AptKeyring::UnsupportedFormatError) do
      Dev::Deps::AptKeyring.content_for(path, BINARY)
    end

    Then "the message names the path and the way out"
    error.message.include?("vendor.asc")
    error.message.include?("armored")

    Cleanup
    nil
  end

  test "content that is neither armor nor a public-key packet is refused" do
    Given "an HTML error page where a key should be"
    html = "<!DOCTYPE html><html>404</html>"

    When
    error = assert_raises(Dev::Deps::AptKeyring::UnsupportedFormatError) do
      Dev::Deps::AptKeyring.content_for("/etc/apt/keyrings/x.key", html)
    end

    Then
    error.message.include?("x.key")

    Cleanup
    nil
  end

  test "a truncated armor block (no END line) is refused rather than half-decoded" do
    Given
    truncated = armored.sub(/-----END.*\n/, "")

    When
    assert_raises(Dev::Deps::AptKeyring::UnsupportedFormatError) do
      Dev::Deps::AptKeyring.content_for("/etc/apt/keyrings/x.key", truncated)
    end

    Then
    true

    Cleanup
    nil
  end

  test "accepted? mirrors apt's loader: extension decides the parser, the first bytes decide the verdict" do
    Given
    cases = [
      ["/k/a.key", BINARY, true],
      ["/k/a.gpg", BINARY, true],
      ["/k/a.key", armored, false], # the resolute failure: armor at a non-.asc path
      ["/k/a.asc", armored, true],
      ["/k/a.asc", BINARY, false],
      ["/k/a.key", "", false],
      ["/k/a.key", "<html>", false],
    ]

    When
    verdicts = cases.map { |path, bytes, _| Dev::Deps::AptKeyring.accepted?(path, bytes) }

    Then
    verdicts == cases.map(&:last)

    Cleanup
    nil
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/artifact"

transform!(RSpock::AST::Transformation)
class Dev::Deps::ArtifactTest < Minitest::Test
  test "carries the uri and the published digest dev will enforce" do
    Given "an artifact with a published digest"
    artifact = Dev::Deps::Artifact.new(uri: "https://example.com/a.zip", digest: "SHA256=abc")

    Expect
    artifact.uri == "https://example.com/a.zip"
    artifact.digest == "SHA256=abc"
  end

  test "a nil digest means upstream publishes none" do
    Given "an artifact from a service that publishes no digests"
    artifact = Dev::Deps::Artifact.new(uri: "https://example.com/a.tar.gz")

    Expect "the uri stands and the digest is absent (trust-on-first-use at fetch)"
    artifact.uri == "https://example.com/a.tar.gz"
    artifact.digest.nil?
  end

  test "rejects a payload with no uri" do
    When "a backing service omits the download location"
    Dev::Deps::Artifact.new(uri: nil)

    Then
    raises Dev::Deps::Artifact::MissingUriError
  end

  test "rejects a payload with a blank uri" do
    When "a backing service returns an empty download location"
    Dev::Deps::Artifact.new(uri: "")

    Then
    raises Dev::Deps::Artifact::MissingUriError
  end

  test "is value-equal" do
    Given "two artifacts describing the same bytes"
    a = Dev::Deps::Artifact.new(uri: "https://example.com/a.zip", digest: "SHA256=abc")
    b = Dev::Deps::Artifact.new(uri: "https://example.com/a.zip", digest: "SHA256=abc")

    Expect
    a == b
    a.hash == b.hash
  end

  test "the same uri with a different digest is a different artifact" do
    Given "two artifacts at one uri with differing digests"
    a = Dev::Deps::Artifact.new(uri: "https://example.com/a.zip", digest: "SHA256=abc")
    b = Dev::Deps::Artifact.new(uri: "https://example.com/a.zip", digest: "SHA256=def")

    Expect
    a != b
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::ReleaseTagTest < Minitest::Test
  test "a release's tag is v<version>, the ref its deploys are recorded against" do
    Given
    tag = Dev::Lifecycle::ReleaseTag.new("1.2.0")

    Expect
    tag.version == "1.2.0"
    tag.name == "v1.2.0"
    tag.to_s == "v1.2.0"
    tag == Dev::Lifecycle::ReleaseTag.new("1.2.0")
    tag != Dev::Lifecycle::ReleaseTag.new("1.2.1")
    tag.frozen?
  end

  test "#{version.inspect} cannot name a release" do
    When
    Dev::Lifecycle::ReleaseTag.new(version)

    Then
    error = raises Dev::Lifecycle::ReleaseTag::InvalidVersionError
    error.message.include?("a version is one word")

    Where
    version
    ""
    "1.2 0"
    "a/b"
  end
end

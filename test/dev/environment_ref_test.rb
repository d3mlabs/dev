# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/environment_image"
require "dev/environment_ref"

transform!(RSpock::AST::Transformation)
class Dev::EnvironmentRefTest < Minitest::Test
  test "parse reads the reserved word as the host and any other name as an image's: #{value.inspect}" do
    When
    ref = Dev::EnvironmentRef.parse(value)

    Then
    ref == expected
    ref.to_s == value

    Where
    value          | expected
    "host"         | Dev::EnvironmentRef::Host.new
    "snappy-linux" | Dev::EnvironmentRef::Image.new(name: "snappy-linux")
  end

  test "the reserved word is the one an image block may not be named" do
    Expect
    Dev::EnvironmentRef::HOST == Dev::EnvironmentImage::HOST
    Dev::EnvironmentRef::HOST == "host"
  end

  test "references are values: equal by shape and name, usable as hash keys" do
    Given
    host = Dev::EnvironmentRef::Host.new
    linux = Dev::EnvironmentRef::Image.new(name: "snappy-linux")
    server = Dev::EnvironmentRef::Image.new(name: "snappy-server")

    Expect
    host == Dev::EnvironmentRef::Host.new
    host.hash == Dev::EnvironmentRef::Host.new.hash
    linux == Dev::EnvironmentRef::Image.new(name: "snappy-linux")
    linux.hash == Dev::EnvironmentRef::Image.new(name: "snappy-linux").hash
    linux != server
    linux != host
    host != "host"
    { host => 1, linux => 2 }[Dev::EnvironmentRef::Image.new(name: "snappy-linux")] == 2
  end

  test "an image reference carries its name unresolved" do
    Expect
    Dev::EnvironmentRef::Image.new(name: "snappy-linux").name == "snappy-linux"
  end
end

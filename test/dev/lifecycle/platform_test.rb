# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::PlatformTest < Minitest::Test
  test "the id set is closed and spelled one way: #{id}" do
    Expect
    Dev::Lifecycle::Platform.parse(id) == platform
    Dev::Lifecycle::Platform.id?(id)
    platform.to_s == id
    platform.serialize == id

    Where
    id        | platform
    "win64"   | Dev::Lifecycle::Platform::Win64
    "linux64" | Dev::Lifecycle::Platform::Linux64
    "macos"   | Dev::Lifecycle::Platform::Macos
  end

  test "ids lists the set in declaration order" do
    Expect
    Dev::Lifecycle::Platform.ids == ["win64", "linux64", "macos"]
  end

  test "parse refuses an id outside the set, listing it: #{id.inspect}" do
    When
    Dev::Lifecycle::Platform.parse(id)

    Then
    error = raises(Dev::Lifecycle::UnknownPlatformError)
    error.message.include?(id.inspect)
    error.message.include?("win64, linux64, macos")
    !Dev::Lifecycle::Platform.id?(id)

    Where
    id
    "Win64"
    "windows-x64"
    "x86_64"
    ""
  end
end

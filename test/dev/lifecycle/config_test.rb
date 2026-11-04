# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::ConfigTest < Minitest::Test
  test "the role set is closed and spelled one way: #{id}" do
    Expect
    Dev::Lifecycle::Config.parse(id) == config
    Dev::Lifecycle::Config.id?(id)
    config.to_s == id
    config.serialize == id

    Where
    id        | config
    "debug"   | Dev::Lifecycle::Config::Debug
    "dev"     | Dev::Lifecycle::Config::Development
    "release" | Dev::Lifecycle::Config::Release
  end

  test "ids lists the set in declaration order" do
    Expect
    Dev::Lifecycle::Config.ids == ["debug", "dev", "release"]
  end

  test "parse refuses a toolchain's own name for a role, listing the set: #{id.inspect}" do
    When
    Dev::Lifecycle::Config.parse(id)

    Then
    error = raises(Dev::Lifecycle::UnknownConfigError)
    error.message.include?(id.inspect)
    error.message.include?("debug, dev, release")
    !Dev::Lifecycle::Config.id?(id)

    Where
    id
    "Development"
    "Shipping"
    "RelWithDebInfo"
    ""
  end
end

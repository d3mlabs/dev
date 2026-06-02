# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/pin"

transform!(RSpock::AST::Transformation)
class Dev::Deps::PinTest < Minitest::Test
  test "creates a pin with all required fields" do
    When
    pin = Dev::Deps::Pin.new(
      name: "boost",
      integration: :cmake,
      group: :app,
      version: "1.90.0",
      hash: "SHA256=deadbeef",
      metadata: { url: "https://example.com/boost.tar.gz" },
    )

    Then
    pin.name == "boost"
    pin.integration == :cmake
    pin.group == :app
    pin.version == "1.90.0"
    pin.hash == "SHA256=deadbeef"
    pin.metadata == { url: "https://example.com/boost.tar.gz" }
  end

  test "pin is frozen (immutable)" do
    Given
    pin = Dev::Deps::Pin.new(
      name: "boost",
      integration: :cmake,
      group: :app,
      version: "1.90.0",
      hash: "SHA256=deadbeef",
      metadata: {},
    )

    Expect
    pin.frozen?
  end

  test "two pins with same fields are equal" do
    Given
    attrs = { name: "boost", integration: :cmake, group: :app, version: "1.90.0", hash: "SHA256=deadbeef", metadata: {} }

    When
    pin_a = Dev::Deps::Pin.new(**attrs)
    pin_b = Dev::Deps::Pin.new(**attrs)

    Then
    pin_a == pin_b
    pin_a.eql?(pin_b)
    pin_a.hash == pin_b.hash
  end

  test "two pins with different fields are not equal" do
    Given
    base = { name: "boost", integration: :cmake, group: :app, version: "1.90.0", hash: "SHA256=deadbeef", metadata: {} }

    When
    pin_a = Dev::Deps::Pin.new(**base)
    pin_b = Dev::Deps::Pin.new(**base.merge(version: "2.0.0"))

    Then
    pin_a != pin_b
  end

  test "metadata defaults to empty hash when nil" do
    When
    pin = Dev::Deps::Pin.new(
      name: "luaunit",
      integration: :luarocks,
      group: :test,
      version: "3.5-1",
      hash: "SHA256=abc",
      metadata: nil,
    )

    Then
    pin.metadata.nil?
  end

  test "pin can be deconstructed to a hash" do
    Given
    pin = Dev::Deps::Pin.new(
      name: "boost",
      integration: :cmake,
      group: :app,
      version: "1.90.0",
      hash: "SHA256=deadbeef",
      metadata: { url: "https://example.com/boost.tar.gz" },
    )

    When
    h = pin.to_h

    Then
    h[:name] == "boost"
    h[:integration] == :cmake
    h[:group] == :app
    h[:version] == "1.90.0"
    h[:hash] == "SHA256=deadbeef"
    h[:metadata] == { url: "https://example.com/boost.tar.gz" }
  end
end

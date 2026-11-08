# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/ficsit_target"

transform!(RSpock::AST::Transformation)
class Dev::Deps::FicsitTargetTest < Minitest::Test
  test "parse reads SMR's three target names and spells them back" do
    Expect
    Dev::Deps::FicsitTarget.parse(name) == target
    target.to_s == name

    Where
    name            | target
    "Windows"       | Dev::Deps::FicsitTarget::Windows
    "WindowsServer" | Dev::Deps::FicsitTarget::WindowsServer
    "LinuxServer"   | Dev::Deps::FicsitTarget::LinuxServer
  end

  test "a name outside the set is refused with the set listed" do
    When
    Dev::Deps::FicsitTarget.parse("windows")

    Then
    e = raises Dev::Deps::UnknownFicsitTargetError
    e.message == 'unknown ficsit target "windows" (expected Windows, WindowsServer, LinuxServer)'
  end
end

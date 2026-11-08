# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/vdf"

transform!(RSpock::AST::Transformation)
class Dev::Deps::VdfTest < Minitest::Test
  test "dump writes the root key over a brace block, every key and scalar quoted, nested hashes as blocks, tabs for depth" do
    When
    text = Dev::Deps::Vdf.dump("AppBuild", { "AppID" => 480, "Desc" => "nightly", "Depots" => { "481" => "depot_build_481.vdf" } })

    Then
    text == <<~VDF
      "AppBuild"
      {
      \t"AppID"\t"480"
      \t"Desc"\t"nightly"
      \t"Depots"
      \t{
      \t\t"481"\t"depot_build_481.vdf"
      \t}
      }
    VDF
  end

  test "dump escapes quotes and backslashes so a Windows path survives" do
    When
    text = Dev::Deps::Vdf.dump("DepotBuild", { "ContentRoot" => "C:\\builds\\\"win64\"" })

    Then
    text == "\"DepotBuild\"\n{\n\t\"ContentRoot\"\t\"C:\\\\builds\\\\\\\"win64\\\"\"\n}\n"
  end

  test "dump of an empty block is the root over empty braces" do
    Expect
    Dev::Deps::Vdf.dump("Empty", {}) == "\"Empty\"\n{\n}\n"
  end
end

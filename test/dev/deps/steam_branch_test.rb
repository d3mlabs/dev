# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/steam_branch"

transform!(RSpock::AST::Transformation)
class Dev::Deps::SteamBranchTest < Minitest::Test
  SteamBranch = Dev::Deps::SteamBranch

  test "writes <app>/<branch> and reads it back" do
    Given
    branch = SteamBranch.new(app: "1690800", branch: "experimental")

    Expect
    branch.to_s == "1690800/experimental"
    SteamBranch.parse(branch.to_s) == branch
  end

  test "the default branch is public" do
    Expect
    SteamBranch.new(app: "1690800").branch == "public"
    SteamBranch.new(app: "1690800").to_s == "1690800/public"
  end

  test "#{source.inspect} is not a Steam branch coordinate" do
    When
    SteamBranch.parse(source)

    Then
    raises SteamBranch::InvalidSourceError

    Where
    source
    ""
    "1690800"
    "1690800/"
    "/public"
  end

  test "coordinates compare by value" do
    Expect
    SteamBranch.parse("1690800/public") == SteamBranch.new(app: "1690800")
    SteamBranch.parse("1690800/public") != SteamBranch.parse("1690800/experimental")
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/steam_cmd"

transform!(RSpock::AST::Transformation)
class Dev::Deps::SteamCmdTest < Minitest::Test
  APP_INFO = <<~VDF
    "1690800"
    {
      "common" { "name" "Satisfactory Dedicated Server" }
      "depots"
      {
        "branches"
        {
          "public"
          {
            "buildid"  "15321746"
            "timeupdated"  "1700000000"
          }
          "experimental"
          {
            "buildid"  "15400000"
            "timeupdated"  "1700000001"
          }
        }
      }
    }
  VDF

  test "parse_build_id extracts the buildid for the requested branch" do
    When "parsing the public branch"
    public_build = Dev::Deps::SteamCmd.parse_build_id(APP_INFO, "public")
    experimental_build = Dev::Deps::SteamCmd.parse_build_id(APP_INFO, "experimental")

    Then
    public_build == "15321746"
    experimental_build == "15400000"
  end

  test "parse_build_id returns nil for an unknown branch" do
    When "parsing a missing branch"
    result = Dev::Deps::SteamCmd.parse_build_id(APP_INFO, "nonexistent")

    Then
    result.nil?
  end

  test "resolve_build_id returns the parsed buildid on success" do
    Given "a successful app_info_print"
    Dev::Deps::SteamCmd.stubs(:run).returns([APP_INFO, "", stub(success?: true)])

    When "resolving"
    build_id = Dev::Deps::SteamCmd.resolve_build_id(app: 1690800, branch: "public")

    Then
    build_id == "15321746"
  end

  test "resolve_build_id raises when steamcmd fails" do
    Given "a failing app_info_print"
    Dev::Deps::SteamCmd.stubs(:run).returns(["", "Connection error", stub(success?: false)])

    When "resolving"
    Dev::Deps::SteamCmd.resolve_build_id(app: 1690800, branch: "public")

    Then
    raises Dev::Deps::SteamCmd::SteamCmdError
  end

  test "resolve_build_id raises when the branch has no buildid" do
    Given "output missing the requested branch"
    Dev::Deps::SteamCmd.stubs(:run).returns([APP_INFO, "", stub(success?: true)])

    When "resolving a missing branch"
    Dev::Deps::SteamCmd.resolve_build_id(app: 1690800, branch: "nonexistent")

    Then
    raises Dev::Deps::SteamCmd::SteamCmdError
  end

  test "download_url matches the host OS" do
    When "selecting the SteamCMD tarball URL"
    url = Dev::Deps::SteamCmd.download_url

    Then "darwin gets the osx tarball, everything else the linux tarball"
    expected = RUBY_PLATFORM.include?("darwin") ? Dev::Deps::SteamCmd::MACOS_URL : Dev::Deps::SteamCmd::LINUX_URL
    url == expected
  end
end

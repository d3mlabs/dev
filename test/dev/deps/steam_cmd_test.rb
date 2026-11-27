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

  test "parse_branches extracts every branch's buildid" do
    When "parsing the branches section"
    branches = Dev::Deps::SteamCmd.parse_branches(APP_INFO)

    Then
    branches == { "public" => "15321746", "experimental" => "15400000" }
  end

  test "parse_branches skips branches without a buildid and handles no section" do
    Given "a redacted branch alongside a normal one, and empty output"
    vdf = <<~VDF
      "branches"
      {
        "public" { "buildid" "42" }
        "gated" { "pwdrequired" "1" }
      }
    VDF

    When "parsing"
    branches = Dev::Deps::SteamCmd.parse_branches(vdf)
    empty = Dev::Deps::SteamCmd.parse_branches("no branches here")

    Then
    branches == { "public" => "42" }
    empty == {}
  end

  # A warm install dir whose steamcmd.sh is the given shell script.
  #
  # @return [String] the install dir
  def warm_dir(script_body)
    dir = Dir.mktmpdir("steamcmd-test-")
    script = File.join(dir, "steamcmd.sh")
    File.write(script, "#!/bin/sh\n#{script_body}")
    File.chmod(0o755, script)
    dir
  end

  test "resolve_branches returns the parsed branch map on success" do
    Given "a steamcmd.sh whose app_info_print prints the app's branches"
    dir = warm_dir("cat <<'VDF'\n#{APP_INFO}VDF\n")

    When "resolving"
    branches = Dev::Deps::SteamCmd.resolve_branches(app: 1690800, dir: dir)

    Then
    branches == { "public" => "15321746", "experimental" => "15400000" }

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "resolve_branches raises when steamcmd fails" do
    Given "a steamcmd.sh that fails to connect"
    dir = warm_dir("echo 'Connection error' >&2\nexit 1\n")

    When "resolving"
    Dev::Deps::SteamCmd.resolve_branches(app: 1690800, dir: dir)

    Then
    e = raises Dev::Deps::SteamCmd::SteamCmdError
    e.message == "steamcmd app_info_print 1690800 failed: Connection error"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "download_url matches the host OS" do
    When "selecting the SteamCMD tarball URL"
    url = Dev::Deps::SteamCmd.download_url

    Then "darwin gets the osx tarball, everything else the linux tarball"
    expected = RUBY_PLATFORM.include?("darwin") ? Dev::Deps::SteamCmd::MACOS_URL : Dev::Deps::SteamCmd::LINUX_URL
    url == expected
  end

  test "ensure! returns the script path without bootstrapping when it is already executable" do
    Given "a warm install dir with an executable steamcmd.sh"
    dir = Dir.mktmpdir("steamcmd-test-")
    script = File.join(dir, "steamcmd.sh")
    File.write(script, "#!/bin/sh\n")
    File.chmod(0o755, script)

    When "ensuring"
    path = Dev::Deps::SteamCmd.ensure!(dir)

    Then
    path == script

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure! raises BootstrapError when the curl|tar pipeline fails" do
    Given "an empty install dir and a failing download pipeline"
    dir = Dir.mktmpdir("steamcmd-test-")

    When "ensuring"
    Dev::Deps::SteamCmd.ensure!(dir)

    Then
    1 * Kernel.system("sh", "-c", regexp_matches(/curl -fsSL .+ \| tar -xz -C /)) >> false
    raises Dev::Deps::SteamCmd::BootstrapError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "run ensures the install and executes steamcmd.sh with the +commands" do
    Given "a warm install dir whose steamcmd.sh echoes its arguments"
    dir = Dir.mktmpdir("steamcmd-test-")
    script = File.join(dir, "steamcmd.sh")
    File.write(script, "#!/bin/sh\necho \"$@\"\n")
    File.chmod(0o755, script)

    When "running"
    out, _err, status = Dev::Deps::SteamCmd.run("+login", "anonymous", dir: dir)

    Then
    out == "+login anonymous\n"
    status.success? == true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure! raises BootstrapError when the pipeline succeeds but produces no script" do
    Given "an empty install dir and a pipeline that extracts nothing"
    dir = Dir.mktmpdir("steamcmd-test-")

    When "ensuring"
    Dev::Deps::SteamCmd.ensure!(dir)

    Then
    1 * Kernel.system("sh", "-c", regexp_matches(/curl -fsSL .+ \| tar -xz -C /)) >> true
    raises Dev::Deps::SteamCmd::BootstrapError

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

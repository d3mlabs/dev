# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/steam_app_build"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::SteamAppBuildTest < Minitest::Test
  def setup
    @scratch = Pathname(Dir.mktmpdir("steam-app-build-"))
  end

  def teardown
    FileUtils.rm_rf(@scratch)
    super
  end

  test "write lays one depot script per depot and the app script naming them under scripts/, and creates the build output" do
    Given "two depots with their content roots"
    build = Dev::Deps::SteamAppBuild.new(
      app: 480,
      desc: "cellbound-3d-steamworks-win64-release (1.2.0+3f2a1c9d8e7b)",
      depots: { 481 => @scratch / "depots/481", 482 => @scratch / "depots/482" },
      build_output: @scratch / "output",
      set_live: "beta",
    )

    When
    app_script = build.write(@scratch)

    Then "the app script references the depot scripts by file name, as steamcmd resolves them beside it"
    app_script == @scratch / "scripts/app_build_480.vdf"
    app_script.read == <<~VDF
      "AppBuild"
      {
      \t"AppID"\t"480"
      \t"Desc"\t"cellbound-3d-steamworks-win64-release (1.2.0+3f2a1c9d8e7b)"
      \t"BuildOutput"\t"#{@scratch}/output"
      \t"ContentRoot"\t"."
      \t"SetLive"\t"beta"
      \t"Depots"
      \t{
      \t\t"481"\t"depot_build_481.vdf"
      \t\t"482"\t"depot_build_482.vdf"
      \t}
      }
    VDF
    (@scratch / "scripts/depot_build_481.vdf").read == <<~VDF
      "DepotBuild"
      {
      \t"DepotID"\t"481"
      \t"ContentRoot"\t"#{@scratch}/depots/481"
      \t"FileMapping"
      \t{
      \t\t"LocalPath"\t"*"
      \t\t"DepotPath"\t"."
      \t\t"Recursive"\t"1"
      \t}
      }
    VDF
    (@scratch / "scripts/depot_build_482.vdf").file?
    (@scratch / "output").directory?
  end

  test "without a branch to set live the SetLive key is empty, which steamcmd reads as upload only" do
    Given
    build = Dev::Deps::SteamAppBuild.new(app: 480, desc: "d", depots: { 481 => @scratch / "depots/481" }, build_output: @scratch / "output")

    When
    app_script = build.write(@scratch)

    Then
    app_script.read.include?("\t\"SetLive\"\t\"\"\n")
  end
end

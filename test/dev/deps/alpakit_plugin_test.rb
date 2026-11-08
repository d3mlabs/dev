# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/alpakit_plugin"
require "support/alpakit_fixtures"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::AlpakitPluginTest < Minitest::Test
  include AlpakitFixtures

  def setup
    @root = Pathname(Dir.mktmpdir("alpakit-plugin-"))
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  test "read takes the mod reference from the root .uplugin and the target from Content/Paks/<target>/" do
    Given "a staged LinuxServer plugin with a binary"
    dir = stage_plugin(@root / "linux", mod_reference: "Snappy", target: "LinuxServer",
      binaries: { "Binaries/Linux/libFactoryServer-Snappy-Linux-Shipping.so" => "so" })

    When
    plugin = Dev::Deps::AlpakitPlugin.read(dir)

    Then "both facts are read from the tree, and the file list is relative and sorted"
    plugin.mod_reference == "Snappy"
    plugin.target == Dev::Deps::FicsitTarget::LinuxServer
    plugin.uplugin == dir / "Snappy.uplugin"
    plugin.files.map(&:to_s) == [
      "Binaries/Linux/libFactoryServer-Snappy-Linux-Shipping.so",
      "Content/Paks/LinuxServer/SnappyFactoryGame-LinuxServer.pak",
      "Resources/Icon128.png",
      "Snappy.uplugin",
    ]
    plugin.to_s == "Snappy (LinuxServer)"
  end

  test "a tree without a root .uplugin is not a plugin" do
    Given "a tree whose descriptor sits one level down"
    dir = stage_plugin(@root / "nested" / "Snappy", mod_reference: "Snappy", target: "Windows")

    When
    Dev::Deps::AlpakitPlugin.read(@root / "nested")

    Then
    e = raises Dev::Deps::AlpakitPlugin::NotAPluginError
    e.message.include?("found none")
    dir.directory?
  end

  test "a tree with two root .uplugin files is not a plugin" do
    Given
    dir = stage_plugin(@root / "two", mod_reference: "Snappy", target: "Windows")
    (dir / "Other.uplugin").write("{}")

    When
    Dev::Deps::AlpakitPlugin.read(dir)

    Then
    e = raises Dev::Deps::AlpakitPlugin::NotAPluginError
    e.message.include?("Other.uplugin")
  end

  test "a tree with no cooked paks says nothing about its target" do
    Given
    dir = stage_plugin(@root / "nopaks", mod_reference: "Snappy", target: "Windows")
    FileUtils.rm_rf(dir / "Content")

    When
    Dev::Deps::AlpakitPlugin.read(dir)

    Then
    raises Dev::Deps::AlpakitPlugin::NoTargetError
  end

  test "a tree cooked for two targets is not one Alpakit zip" do
    Given
    dir = stage_plugin(@root / "both", mod_reference: "Snappy", target: "Windows")
    (dir / "Content" / "Paks" / "LinuxServer").mkpath

    When
    Dev::Deps::AlpakitPlugin.read(dir)

    Then
    e = raises Dev::Deps::AlpakitPlugin::SeveralTargetsError
    e.message.include?("LinuxServer, Windows")
  end

  test "a paks directory SMR has no target for is refused with the set named" do
    Given
    dir = stage_plugin(@root / "mac", mod_reference: "Snappy", target: "Mac")

    When
    Dev::Deps::AlpakitPlugin.read(dir)

    Then
    e = raises Dev::Deps::UnknownFicsitTargetError
    e.message == 'unknown ficsit target "Mac" (expected Windows, WindowsServer, LinuxServer)'
  end
end

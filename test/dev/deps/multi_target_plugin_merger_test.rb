# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/multi_target_plugin_merger"
require "support/alpakit_fixtures"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::MultiTargetPluginMergerTest < Minitest::Test
  include AlpakitFixtures

  STEAM_DLL = "Binaries/Win64/FactoryGameSteam-Snappy-Win64-Shipping.dll"
  EGS_DLL = "Binaries/Win64/FactoryGameEGS-Snappy-Win64-Shipping.dll"
  SERVER_SO = "Binaries/Linux/libFactoryServer-Snappy-Linux-Shipping.so"

  def setup
    @root = Pathname(Dir.mktmpdir("multi-target-merge-"))
    @scratch = @root / "store" / ".ficsit"
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  def new_merger(**options)
    Dev::Deps::MultiTargetPluginMerger.new(**options)
  end

  test "three per-target zips — two of them Windows — merge into one zip laid out per target, the shared Windows files unioned" do
    Given "snappy's Steam and Epic client builds (one Windows tree each, same content, different binaries) and its server build"
    steam = alpakit_zip(@root, "snappy-steam-win64", mod_reference: "Snappy", target: "Windows", binaries: { STEAM_DLL => "steam" })
    egs = alpakit_zip(@root, "snappy-egs-win64", mod_reference: "Snappy", target: "Windows", binaries: { EGS_DLL => "egs" })
    server = alpakit_zip(@root, "snappy-server-linux64", mod_reference: "Snappy", target: "LinuxServer", binaries: { SERVER_SO => "so" })

    When
    plugin = new_merger.merge([steam, egs, server], scratch: @scratch)

    Then "the zip is <ModRef>.zip in the scratch, every entry under a target directory, each target carrying its own .uplugin; the shipments are untouched"
    plugin.archive == @scratch / "Snappy.zip"
    plugin.mod_reference == "Snappy"
    plugin.targets == [Dev::Deps::FicsitTarget::Windows, Dev::Deps::FicsitTarget::LinuxServer]
    plugin.size == plugin.archive.size
    plugin.to_s == "Snappy (Windows, LinuxServer)"
    zip_entries(plugin.archive) == [
      "LinuxServer/#{SERVER_SO}",
      "LinuxServer/Content/Paks/LinuxServer/SnappyFactoryGame-LinuxServer.pak",
      "LinuxServer/Resources/Icon128.png",
      "LinuxServer/Snappy.uplugin",
      "Windows/#{EGS_DLL}",
      "Windows/#{STEAM_DLL}",
      "Windows/Content/Paks/Windows/SnappyFactoryGame-Windows.pak",
      "Windows/Resources/Icon128.png",
      "Windows/Snappy.uplugin",
    ]
    zip_entries(steam) == [STEAM_DLL, "Content/Paks/Windows/SnappyFactoryGame-Windows.pak", "Resources/Icon128.png", "Snappy.uplugin"]
  end

  test "a second merge rebuilds the layout from scratch: nothing of the first survives" do
    Given "a first merge of two targets"
    steam = alpakit_zip(@root, "steam", mod_reference: "Snappy", target: "Windows", binaries: { STEAM_DLL => "steam" })
    server = alpakit_zip(@root, "server", mod_reference: "Snappy", target: "LinuxServer", binaries: { SERVER_SO => "so" })
    new_merger.merge([steam, server], scratch: @scratch)

    When "the next deploy ships the server only"
    plugin = new_merger.merge([server], scratch: @scratch)

    Then "the Windows tree is gone from the layout and the zip"
    plugin.targets == [Dev::Deps::FicsitTarget::LinuxServer]
    zip_entries(plugin.archive).none? { |entry| entry.start_with?("Windows/") }
    !(@scratch / "merge" / "Snappy" / "Windows").exist?
  end

  test "two builds of one target carrying a file with different bytes are refused, both archives named" do
    Given "Steam and Epic builds whose cooked pak differs"
    steam = alpakit_zip(@root, "snappy-steam-win64", mod_reference: "Snappy", target: "Windows", binaries: { STEAM_DLL => "steam" }, pak: "cook A")
    egs = alpakit_zip(@root, "snappy-egs-win64", mod_reference: "Snappy", target: "Windows", binaries: { EGS_DLL => "egs" }, pak: "cook B")

    When
    new_merger.merge([steam, egs], scratch: @scratch)

    Then
    e = raises Dev::Deps::MultiTargetPluginMerger::ConflictingFileError
    e.message.include?("Windows/Content/Paks/Windows/SnappyFactoryGame-Windows.pak differs between snappy-steam-win64.zip and snappy-egs-win64.zip")
  end

  test "archives of two different mods do not merge" do
    Given
    snappy = alpakit_zip(@root, "snappy", mod_reference: "Snappy", target: "Windows")
    other = alpakit_zip(@root, "other", mod_reference: "Other", target: "LinuxServer")

    When
    new_merger.merge([snappy, other], scratch: @scratch)

    Then
    e = raises Dev::Deps::MultiTargetPluginMerger::MixedModReferencesError
    e.message.include?("snappy.zip is Snappy, other.zip is Other")
  end

  test "targets staged from different descriptors do not merge: SMR takes one .uplugin per version" do
    Given "a server plugin whose SemVersion moved on"
    client = alpakit_zip(@root, "snappy-steam-win64", mod_reference: "Snappy", target: "Windows")
    server = alpakit_zip(@root, "snappy-server-linux64", mod_reference: "Snappy", target: "LinuxServer",
      uplugin: AlpakitFixtures::UPLUGIN.sub("1.2.0", "1.3.0"))

    When
    new_merger.merge([client, server], scratch: @scratch)

    Then
    e = raises Dev::Deps::MultiTargetPluginMerger::DifferingUpluginError
    e.message.include?("Snappy.uplugin differs between snappy-steam-win64.zip and snappy-server-linux64.zip")
  end

  test "an archive that is not a zip fails at unpacking, with unzip's exit" do
    Given
    not_a_zip = @root / "snappy-steam-win64.zip"
    not_a_zip.write("not a zip")

    When
    new_merger.merge([not_a_zip], scratch: @scratch)

    Then
    e = raises Dev::Deps::MultiTargetPluginMerger::UnpackFailedError
    e.message.include?("unzip exited")
  end

  test "an archive that unpacks to something other than an Alpakit plugin is the reader's refusal" do
    Given "a zip with no .uplugin"
    dir = @root / "plain"
    dir.mkpath
    (dir / "README").write("hi")
    zip = zip_plugin(dir, @root / "plain.zip")

    When
    new_merger.merge([zip], scratch: @scratch)

    Then
    raises Dev::Deps::AlpakitPlugin::NotAPluginError
  end

  test "a merged zip at or over SMR's limit is refused before any upload" do
    Given "a merger with a limit the smallest zip exceeds"
    steam = alpakit_zip(@root, "steam", mod_reference: "Snappy", target: "Windows")

    When
    new_merger(size_limit: Dev::Lifecycle::ByteSize.new(bytes: 16)).merge([steam], scratch: @scratch)

    Then
    e = raises Dev::Deps::MultiTargetPluginMerger::PluginTooLargeError
    e.message.include?("ficsit.app takes less than 16")
  end

  test "SMR's limit is the decimal gigabyte smr-api enforces" do
    Expect
    Dev::Deps::MultiTargetPluginMerger::SMR_SIZE_LIMIT.bytes == 1_000_000_000
  end

  test "nothing to merge is refused" do
    When
    new_merger.merge([], scratch: @scratch)

    Then
    raises Dev::Deps::MultiTargetPluginMerger::NothingToMergeError
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/steam_repository"
require "dev/lifecycle"
require "support/lifecycle_fixtures"
require "fileutils"
require "pathname"
require "time"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::SteamRepositoryTest < Minitest::Test
  include LifecycleFixtures

  NOON = Time.utc(2026, 11, 4, 12, 0, 0)
  BUILT = "Successfully finished AppID 480 build (BuildID 9876543).\n"

  def setup
    @root = Pathname(Dir.mktmpdir("steam-publish-"))
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  def id
    Dev::Deps::PackageId.new(integration: :steam, name: "SatisfactoryServer", source: "1690800")
  end

  # A real zip of a one-file install, wrapped as the shipment deploy hands a publisher.
  def shipment(build_name)
    install = @root / "installs" / build_name
    install.mkpath
    (install / "#{build_name}.bin").write(build_name)
    dir = @root / "store" / build_name
    packed = Dev::Lifecycle::Archive.new.package(build(build_name), install, dir / build_name)
    manifest = Dev::Lifecycle::Manifest::Artifact.new(
      stamp: Dev::Lifecycle::Manifest::Stamp.now(dev_version: "0.7.2", now: NOON),
      build: build(build_name),
      state: Dev::Lifecycle::GitState.new(sha: "3f2a1c9d8e7b", dirty: false),
      packaged_at: NOON,
      builder: "script",
      builder_version: nil,
      build_id: Dev::Lifecycle::BuildId.new("1.2.0+3f2a1c9d8e7b"),
      archive: packed.name,
      archive_sha256: "ab" * 32,
    )
    Dev::Lifecycle::Shipment.of_artifact(Dev::Lifecycle::Artifact.new(dir:, manifest:))
  end

  def channel(options)
    Dev::Lifecycle::Channel.new(
      name: "steam",
      accepts: [Dev::Lifecycle::BuildPattern.parse("cellbound-3d-steamworks", all_targets), Dev::Lifecycle::BuildPattern.parse("cellbound-3d-server", all_targets)],
      publisher: Dev::Lifecycle::PublisherSpec::Integration.new(name: "steam"),
      options: { "app" => 480, "depots" => { "cellbound-3d-steamworks" => 481, "cellbound-3d-server" => 482 } }.merge(options),
    )
  end

  def status_of(program)
    _pid, status = Process.wait2(Process.spawn(program))
    status
  end

  # Stub the steamcmd boundary, capturing the login script while it exists.
  def steamcmd_replies(out, exit_with: "true")
    Dev::Credentials.stubs(:resolve).with(has_entries(namespace: "steam", key: "username", env_var: "STEAM_USERNAME")).returns("builder")
    Dev::Credentials.stubs(:load).with("steam", "password").returns("hunter2")
    captured = {}
    Dev::Deps::SteamCmd.stubs(:run).with do |flag, script|
      captured[:argv] = [flag, script]
      captured[:script] = File.read(script)
      captured[:mode] = File.stat(script).mode & 0o777
      true
    end.returns([out, "", status_of(exit_with)])
    captured
  end

  test "publish unpacks each archive into its depot's content root, writes the scripts, logs in through a 0600 runscript and reports the BuildID" do
    Given "a testing deploy of two depots, steamcmd reporting a build"
    scratch = @root / "store/.steam"
    captured = steamcmd_replies("Logging in user 'builder' to Steam Public...OK\n#{BUILT}")
    win64 = shipment("cellbound-3d-steamworks-win64-release")
    linux64 = shipment("cellbound-3d-server-linux64-release")

    When
    receipt = Dev::Deps::SteamRepository.new.publish([win64, linux64], channel: channel({}), track: Dev::Lifecycle::Track::Testing, scratch:)

    Then "the receipt names the build, the depots and the branch set live"
    receipt == Dev::Lifecycle::Receipt.new(summary: "steam build 9876543 of app 480 (depots 481, 482) set live on beta")
    (scratch / "depots/481/cellbound-3d-steamworks-win64-release.bin").read == "cellbound-3d-steamworks-win64-release"
    (scratch / "depots/482/cellbound-3d-server-linux64-release.bin").read == "cellbound-3d-server-linux64-release"
    app_script = scratch / "scripts/app_build_480.vdf"
    app_script.read.include?("\t\"SetLive\"\t\"beta\"\n")
    app_script.read.include?("\t\t\"481\"\t\"depot_build_481.vdf\"\n\t\t\"482\"\t\"depot_build_482.vdf\"\n")
    (scratch / "scripts/depot_build_481.vdf").read.include?("\t\"ContentRoot\"\t\"#{scratch}/depots/481\"\n")
    (scratch / "output").directory?
    captured[:argv] == ["+runscript", (scratch / "steamcmd.txt").to_s]
    captured[:mode] == 0o600
    captured[:script] == <<~SCRIPT
      @ShutdownOnFailedCommand 1
      @NoPromptForPassword 1
      login builder hunter2
      run_app_build #{app_script}
      quit
    SCRIPT
    !(scratch / "steamcmd.txt").exist?
  end

  test "a live deploy uploads without setting live — Steam's default branch is set live in Steamworks — and the receipt says where" do
    Given
    scratch = @root / "store/.steam"
    steamcmd_replies(BUILT)

    When
    receipt = Dev::Deps::SteamRepository.new.publish([shipment("cellbound-3d-steamworks-win64-release")], channel: channel({}), track: Dev::Lifecycle::Track::Live, scratch:)

    Then
    receipt.summary == "steam build 9876543 of app 480 (depots 481) uploaded — set it live on the default branch in Steamworks: " \
      "https://partner.steamgames.com/apps/builds/480"
    (scratch / "scripts/app_build_480.vdf").read.include?("\t\"SetLive\"\t\"\"\n")
  end

  test "a live branch the options name is set live like any other" do
    Given
    steamcmd_replies(BUILT)

    When
    receipt = Dev::Deps::SteamRepository.new.publish(
      [shipment("cellbound-3d-steamworks-win64-release")],
      channel: channel({ "branches" => { "live" => "staging" } }), track: Dev::Lifecycle::Track::Live, scratch: @root / "store/.steam",
    )

    Then
    receipt.summary == "steam build 9876543 of app 480 (depots 481) set live on staging"
  end

  test "without a stored password the login names the account alone, for steamcmd's cached token" do
    Given
    Dev::Credentials.stubs(:resolve).returns("builder")
    Dev::Credentials.stubs(:load).with("steam", "password").returns(nil)
    captured = {}
    Dev::Deps::SteamCmd.stubs(:run).with do |_flag, script|
      captured[:script] = File.read(script)
      true
    end.returns([BUILT, "", status_of("true")])

    When
    Dev::Deps::SteamRepository.new.publish([shipment("cellbound-3d-steamworks-win64-release")], channel: channel({}), track: Dev::Lifecycle::Track::Testing, scratch: @root / "store/.steam")

    Then
    captured[:script].include?("\nlogin builder\n")
  end

  test "a failing steamcmd is an UploadFailedError carrying its last lines, and the login script is removed" do
    Given
    scratch = @root / "store/.steam"
    steamcmd_replies("Logging in user 'builder' to Steam Public...\nFAILED (Invalid Password)\n", exit_with: "false")

    When
    Dev::Deps::SteamRepository.new.publish([shipment("cellbound-3d-steamworks-win64-release")], channel: channel({}), track: Dev::Lifecycle::Track::Testing, scratch:)

    Then
    error = raises Dev::Deps::SteamRepository::UploadFailedError
    error.message == "steamcmd run_app_build app_build_480.vdf exited 1: Logging in user 'builder' to Steam Public...\nFAILED (Invalid Password)"
    !(scratch / "steamcmd.txt").exist?
  end

  test "a steamcmd that exits 0 without a BuildID is a BuildIdNotReportedError" do
    Given
    steamcmd_replies("Loading Steam API...OK\n")

    When
    Dev::Deps::SteamRepository.new.publish([shipment("cellbound-3d-steamworks-win64-release")], channel: channel({}), track: Dev::Lifecycle::Track::Testing, scratch: @root / "store/.steam")

    Then
    error = raises Dev::Deps::SteamRepository::BuildIdNotReportedError
    error.message == "steamcmd finished app_build_480.vdf without reporting a BuildID:\nLoading Steam API...OK"
  end

  test "the options are checked before anything is unpacked or run" do
    Given "a channel with no depots, and a steamcmd that must not be reached"
    Dev::Deps::SteamCmd.expects(:run).never
    bad = Dev::Lifecycle::Channel.new(
      name: "steam", accepts: [Dev::Lifecycle::BuildPattern.parse("cellbound-3d-steamworks", all_targets)],
      publisher: Dev::Lifecycle::PublisherSpec::Integration.new(name: "steam"), options: { "app" => 480 },
    )

    When
    Dev::Deps::SteamRepository.new.publish([shipment("cellbound-3d-steamworks-win64-release")], channel: bad, track: Dev::Lifecycle::Track::Testing, scratch: @root / "store/.steam")

    Then
    raises Dev::Deps::SteamChannelOptions::MissingOptionError
    !(@root / "store/.steam").exist?
  end

  test "find reports every branch's current buildid, one version per branch" do
    Given "an app with public and experimental branch tips"
    repo = Dev::Deps::SteamRepository.new
    Dev::Deps::SteamCmd.stubs(:resolve_branches)
                       .with(app: "1690800")
                       .returns({ "public" => "15321746", "experimental" => "15400000" })

    When "finding"
    package = repo.find(id)

    Then "each branch tip is a version, its branch riding metadata as a fact"
    package.versions.map(&:version).sort == ["15321746", "15400000"]
    public_tip = package.version("15321746")
    public_tip.digest.nil?
    public_tip.metadata == { "app" => "1690800", "branch" => "public" }
    package.version("15400000").metadata["branch"] == "experimental"
  end

  test "find claims self-contained declarations — SteamCMD delivers the whole tree" do
    Given "a single-branch app"
    repo = Dev::Deps::SteamRepository.new
    Dev::Deps::SteamCmd.stubs(:resolve_branches).returns({ "public" => "1" })

    When "finding"
    package = repo.find(id)

    Then
    package.version("1").declarations == Dev::Deps::Declarations::Resolved.new([])
  end

  test "find raises PackageNotFoundError when no branch reports a buildid" do
    Given "an app steamcmd reports no branches for"
    repo = Dev::Deps::SteamRepository.new
    Dev::Deps::SteamCmd.stubs(:resolve_branches).returns({})

    When "finding"
    repo.find(id)

    Then
    raises Dev::Deps::Repository::PackageNotFoundError
  end
end

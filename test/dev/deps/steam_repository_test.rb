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
  include SorbetHelper

  NOON = Time.utc(2026, 11, 4, 12, 0, 0)
  BUILT = "Successfully finished AppID 480 build (BuildID 9876543).\n"

  def setup
    @root = Pathname(Dir.mktmpdir("steam-publish-"))
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  def id(branch: "public")
    Dev::Deps::PackageId.new(integration: :steam, name: "SatisfactoryServer", source: "1690800/#{branch}")
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

  # A steamcmd whose one run answers `out`, exiting `exit_with` — a fake
  # rather than an interaction, since the login script it is handed exists
  # only for the run's duration: the fake reads it then, into `captured`
  # (argv, script, mode), for the Then to inspect.
  def steamcmd_replying(out, captured, exit_with: 0)
    steam_cmd = typed_mock(Dev::Deps::SteamCmd, class_of: true)
    status = exit_status(exit_with)
    steam_cmd.define_singleton_method(:run) do |flag, script|
      captured[:argv] = [flag, script]
      captured[:script] = File.read(script)
      captured[:mode] = File.stat(script).mode & 0o777
      [out, "", status]
    end
    steam_cmd
  end

  # The lookup of the stored build account, as the repository asks for it.
  def stored_username
    has_entries(namespace: "steam", key: "username", env_var: "STEAM_USERNAME")
  end

  def repository(steam_cmd: typed_mock(Dev::Deps::SteamCmd, class_of: true), credentials: typed_mock(Dev::Credentials, class_of: true))
    Dev::Deps::SteamRepository.new(steam_cmd:, credentials:)
  end

  test "publish unpacks each archive into its depot's content root, writes the scripts, logs in through a 0600 runscript and reports the BuildID" do
    Given "a testing deploy of two depots, steamcmd reporting a build"
    scratch = @root / "store/.steam"
    captured = {}
    credentials = typed_mock(Dev::Credentials, class_of: true)
    repository = repository(steam_cmd: steamcmd_replying("Logging in user 'builder' to Steam Public...OK\n#{BUILT}", captured), credentials:)
    win64 = shipment("cellbound-3d-steamworks-win64-release")
    linux64 = shipment("cellbound-3d-server-linux64-release")

    When
    receipt = repository.publish([win64, linux64], channel: channel({}), track: Dev::Lifecycle::Track::Testing, scratch:)

    Then "the receipt names the build, the depots and the branch set live"
    1 * credentials.resolve(stored_username) >> "builder"
    1 * credentials.load("steam", "password") >> "hunter2"
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
    credentials = typed_mock(Dev::Credentials, class_of: true)
    repository = repository(steam_cmd: steamcmd_replying(BUILT, {}), credentials:)

    When
    receipt = repository.publish([shipment("cellbound-3d-steamworks-win64-release")], channel: channel({}), track: Dev::Lifecycle::Track::Live, scratch:)

    Then
    1 * credentials.resolve(stored_username) >> "builder"
    1 * credentials.load("steam", "password") >> "hunter2"
    receipt.summary == "steam build 9876543 of app 480 (depots 481) uploaded — set it live on the default branch in Steamworks: " \
      "https://partner.steamgames.com/apps/builds/480"
    (scratch / "scripts/app_build_480.vdf").read.include?("\t\"SetLive\"\t\"\"\n")
  end

  test "a live branch the options name is set live like any other" do
    Given
    credentials = typed_mock(Dev::Credentials, class_of: true)
    repository = repository(steam_cmd: steamcmd_replying(BUILT, {}), credentials:)

    When
    receipt = repository.publish(
      [shipment("cellbound-3d-steamworks-win64-release")],
      channel: channel({ "branches" => { "live" => "staging" } }), track: Dev::Lifecycle::Track::Live, scratch: @root / "store/.steam",
    )

    Then
    1 * credentials.resolve(stored_username) >> "builder"
    1 * credentials.load("steam", "password") >> "hunter2"
    receipt.summary == "steam build 9876543 of app 480 (depots 481) set live on staging"
  end

  test "without a stored password the login names the account alone, for steamcmd's cached token" do
    Given
    captured = {}
    credentials = typed_mock(Dev::Credentials, class_of: true)
    repository = repository(steam_cmd: steamcmd_replying(BUILT, captured), credentials:)

    When
    repository.publish([shipment("cellbound-3d-steamworks-win64-release")], channel: channel({}), track: Dev::Lifecycle::Track::Testing, scratch: @root / "store/.steam")

    Then
    1 * credentials.resolve(stored_username) >> "builder"
    1 * credentials.load("steam", "password") >> nil
    captured[:script].include?("\nlogin builder\n")
  end

  test "a failing steamcmd is an UploadFailedError carrying its last lines, and the login script is removed" do
    Given
    scratch = @root / "store/.steam"
    credentials = typed_mock(Dev::Credentials, class_of: true)
    steam_cmd = steamcmd_replying("Logging in user 'builder' to Steam Public...\nFAILED (Invalid Password)\n", {}, exit_with: 1)
    repository = repository(steam_cmd:, credentials:)

    When
    repository.publish([shipment("cellbound-3d-steamworks-win64-release")], channel: channel({}), track: Dev::Lifecycle::Track::Testing, scratch:)

    Then
    1 * credentials.resolve(stored_username) >> "builder"
    1 * credentials.load("steam", "password") >> "hunter2"
    error = raises Dev::Deps::SteamRepository::UploadFailedError
    error.message == "steamcmd run_app_build app_build_480.vdf exited 1: Logging in user 'builder' to Steam Public...\nFAILED (Invalid Password)"
    !(scratch / "steamcmd.txt").exist?
  end

  test "a steamcmd that exits 0 without a BuildID is a BuildIdNotReportedError" do
    Given
    credentials = typed_mock(Dev::Credentials, class_of: true)
    repository = repository(steam_cmd: steamcmd_replying("Loading Steam API...OK\n", {}), credentials:)

    When
    repository.publish([shipment("cellbound-3d-steamworks-win64-release")], channel: channel({}), track: Dev::Lifecycle::Track::Testing, scratch: @root / "store/.steam")

    Then
    1 * credentials.resolve(stored_username) >> "builder"
    1 * credentials.load("steam", "password") >> "hunter2"
    error = raises Dev::Deps::SteamRepository::BuildIdNotReportedError
    error.message == "steamcmd finished app_build_480.vdf without reporting a BuildID:\nLoading Steam API...OK"
  end

  test "the options are checked before anything is unpacked or run" do
    Given "a channel with no depots, and a steamcmd that must not be reached"
    steam_cmd = typed_mock(Dev::Deps::SteamCmd, class_of: true)
    bad = Dev::Lifecycle::Channel.new(
      name: "steam", accepts: [Dev::Lifecycle::BuildPattern.parse("cellbound-3d-steamworks", all_targets)],
      publisher: Dev::Lifecycle::PublisherSpec::Integration.new(name: "steam"), options: { "app" => 480 },
    )

    When
    repository(steam_cmd:).publish([shipment("cellbound-3d-steamworks-win64-release")], channel: bad, track: Dev::Lifecycle::Track::Testing, scratch: @root / "store/.steam")

    Then
    0 * steam_cmd.run
    raises Dev::Deps::SteamChannelOptions::MissingOptionError
    !(@root / "store/.steam").exist?
  end

  test "the channel's head is pointed: a branch is a pointer at one build" do
    Expect
    repository.head_strategy == Dev::Lifecycle::HeadStrategy::Pointed
  end

  test "find reports the named branch's current buildid — the one version the coordinate's universe holds" do
    Given "an app with public and experimental branch tips"
    steam_cmd = typed_mock(Dev::Deps::SteamCmd, class_of: true)
    repo = repository(steam_cmd:)

    When "finding each branch"
    public_package = repo.find(id)
    experimental_package = repo.find(id(branch: "experimental"))

    Then "each coordinate's universe is its branch tip, app and branch riding metadata as facts"
    2 * steam_cmd.resolve_branches(app: "1690800") >> { "public" => "15321746", "experimental" => "15400000" }
    public_package.versions.map(&:version) == ["15321746"]
    public_tip = public_package.version("15321746")
    public_tip.digest.nil?
    public_tip.source.nil?
    public_tip.metadata == { "app" => "1690800", "branch" => "public" }
    experimental_package.versions.map(&:version) == ["15400000"]
    experimental_package.version("15400000").metadata["branch"] == "experimental"
  end

  test "find raises BranchNotFoundError for a branch the app does not publish, naming the ones it does" do
    Given
    steam_cmd = typed_mock(Dev::Deps::SteamCmd, class_of: true)
    repo = repository(steam_cmd:)

    When "finding a beta branch"
    repo.find(id(branch: "beta"))

    Then
    1 * steam_cmd.resolve_branches(app: "1690800") >> { "public" => "26000000", "experimental" => "26100000" }
    error = raises(Dev::Deps::SteamRepository::BranchNotFoundError)
    error.message == "SatisfactoryServer: Steam publishes no `beta` branch of app 1690800 (branches: experimental 26100000, public 26000000)"
  end

  test "a missing branch is a PackageNotFoundError — the Resolver's Unresolved verdict, not a crash" do
    Expect
    Dev::Deps::SteamRepository::BranchNotFoundError.ancestors.include?(Dev::Deps::Repository::PackageNotFoundError)
  end

  test "find claims self-contained declarations — SteamCMD delivers the whole tree" do
    Given "a single-branch app"
    steam_cmd = typed_mock(Dev::Deps::SteamCmd, class_of: true)
    repo = repository(steam_cmd:)

    When "finding"
    package = repo.find(id)

    Then
    1 * steam_cmd.resolve_branches(app: "1690800") >> { "public" => "1" }
    package.version("1").declarations == Dev::Deps::Declarations::Resolved.new([])
  end

  test "find raises PackageNotFoundError when no branch reports a buildid" do
    Given "an app steamcmd reports no branches for"
    steam_cmd = typed_mock(Dev::Deps::SteamCmd, class_of: true)
    repo = repository(steam_cmd:)

    When "finding"
    repo.find(id)

    Then
    1 * steam_cmd.resolve_branches(app: "1690800") >> {}
    raises Dev::Deps::Repository::PackageNotFoundError
  end
end

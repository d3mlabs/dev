# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/flag_vocabulary"
require "dev/cli/command"
require "dev/cli/deploy_selector"
require "dev/lifecycle"
require "support/fake_gh"
require "support/release_fixtures"
require "fileutils"
require "pathname"
require "time"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Cli::DeploySelectorTest < Minitest::Test
  include ReleaseFixtures

  NOON = Time.utc(2026, 11, 4, 12, 0, 0)
  CLEAN = Dev::Lifecycle::GitState.new(sha: "3f2a1c9d8e7b", dirty: false)
  MOVED_ON = Dev::Lifecycle::GitState.new(sha: "0000aaaa1111", dirty: false)
  TAG = Dev::Lifecycle::ReleaseTag.new("1.2.0")

  # A node declaring exactly the selector's flags, so the words parse the
  # way the verb's argv does.
  class SelectingVerb < Dev::Cli::LifecycleCommand
    Env = type_member { { fixed: String } }

    def desc
      "selects"
    end

    def flags
      Dev::Cli::DeploySelector::FLAGS
    end

    def before(args:, context:)
      Dev::Cli::Dispatch::Outcome::Done.new
    end

    def seam(env, context:); end

    def after(env, context:); end
  end

  def setup
    @root = Pathname(Dir.mktmpdir("deploy-selector-"))
    @gh = FakeGh.new
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  def store
    Dev::Lifecycle::Store.new(project_name: "cellbound-3d", targets: all_targets, data_root: @root.to_s)
  end

  def release_archives
    Dev::Lifecycle::ReleaseArchives.new(releases: Dev::Lifecycle::GithubReleases.new(gh: @gh), store:, targets: all_targets)
  end

  def channel(*patterns)
    Dev::Lifecycle::Channel.new(
      name: "staging", accepts: patterns.map { |name| Dev::Lifecycle::BuildPattern.parse(name, all_targets) },
      publisher: Dev::Lifecycle::PublisherSpec::Script.new(command: "./bin/stage"),
    )
  end

  def stamp(build_name, state: CLEAN)
    store.stamp(
      Dev::Lifecycle::Manifest::Artifact.new(
        stamp: Dev::Lifecycle::Manifest::Stamp.now(dev_version: "0.7.2", now: NOON),
        build: build(build_name), state:, packaged_at: NOON, builder: "script", builder_version: nil,
        build_id: Dev::Lifecycle::BuildId.new("1.2.0+#{state.sha}"), archive: "#{build_name}.zip", archive_sha256: "ab" * 32,
      ),
    )
  end

  def select(channel, *words, state: CLEAN)
    Dev::Cli::DeploySelector.new(channel:, targets: all_targets, store:, release_archives:).select(parsed_args(SelectingVerb.new, words), state:)
  end

  test "bare: one artifact per accepted (target, platform), in accept order, the config decided by what the store holds" do
    Given "a channel over the client on both platforms and the gem; the store holds one config of each client platform"
    stamp("cellbound-3d-win64-dev")
    stamp("cellbound-3d-linux64-release")
    stamp("rspock")

    When
    selection = select(channel("cellbound-3d", "rspock"))

    Then "and a selection from the store is for the testing track: working artifacts never touch live"
    selection.shipments.map(&:name) == ["cellbound-3d-win64-dev", "cellbound-3d-linux64-release", "rspock"]
    selection.shipments.first.archive == store.root / "cellbound-3d-win64-dev" / "cellbound-3d-win64-dev.zip"
    selection.shipments.first.provenance == Dev::Lifecycle::Provenance::Store.new(state: CLEAN, packaged_at: NOON)
    selection.stale == []
    selection.track == Dev::Lifecycle::Track::Testing
    @gh.calls.empty?
  end

  test "--release selects from the release's archives instead: downloaded, verified, the live track, the tag as provenance" do
    Given "a release carrying one config of each client platform and the gem; the store empty"
    release_on(@gh, { "cellbound-3d-win64-release" => "win", "cellbound-3d-linux64-release" => "linux", "rspock" => "gem" })

    When
    selection = select(channel("cellbound-3d", "rspock"), "--release", "1.2.0")

    Then
    selection.shipments.map(&:name) == ["cellbound-3d-win64-release", "cellbound-3d-linux64-release", "rspock"]
    selection.shipments.map(&:archive) == ["cellbound-3d-win64-release", "cellbound-3d-linux64-release", "rspock"].map { |name| store.release_dir(TAG) / "#{name}-1.2.0.zip" }
    selection.shipments.map(&:provenance).uniq == [Dev::Lifecycle::Provenance::Release.new(tag: TAG, sha: RELEASE_SHA)]
    selection.stale == []
    selection.track == Dev::Lifecycle::Track::Live
  end

  test "--release narrows by the positional and --config like the store does: #{words.inspect}" do
    Given "a release carrying both configs of win64 and the server"
    release_on(@gh, { "cellbound-3d-win64-dev" => "wd", "cellbound-3d-win64-release" => "wr", "cellbound-3d-server-linux64-release" => "s" })

    Expect
    select(channel("cellbound-3d-win64", "cellbound-3d-server"), *words, "--release", "1.2.0").shipments.map(&:name) == selected

    Where
    words                                       | selected
    ["--config", "release"]                     | ["cellbound-3d-win64-release", "cellbound-3d-server-linux64-release"]
    ["cellbound-3d-win64-dev"]                  | ["cellbound-3d-win64-dev"]
    ["cellbound-3d-server"]                     | ["cellbound-3d-server-linux64-release"]
  end

  test "a release carrying two configs of an accepted build is a refusal naming both — --config chooses" do
    Given
    release_on(@gh, { "cellbound-3d-win64-dev" => "wd", "cellbound-3d-win64-release" => "wr" })

    When
    select(channel("cellbound-3d-win64"), "--release", "1.2.0")

    Then
    error = raises(Dev::Cli::DeploySelector::AmbiguousReleaseArchiveError)
    error.message == "v1.2.0 carries 2 archives of 'cellbound-3d-win64': cellbound-3d-win64-dev-1.2.0.zip, cellbound-3d-win64-release-1.2.0.zip — --config chooses"
  end

  test "a build the release carries no archive of is refused: deploy adds nothing to a release" do
    Given "a release of the gem only; the store holds the client, which must not substitute"
    stamp("cellbound-3d-win64-release")
    release_on(@gh, { "rspock" => "gem" })

    When
    select(channel("cellbound-3d-release"), "--release", "1.2.0")

    Then
    error = raises(Dev::Cli::DeploySelector::NotInReleaseError)
    error.message == "v1.2.0 carries no archive of 'cellbound-3d-win64-release' (cellbound-3d-win64-release); it carries rspock — " \
                     "a release ships what `release:` cut into it; deploy adds nothing"
    @gh.downloaded("v1.2.0") == [["release.json"]]
  end

  test "--allow-stale beside --release is refused: a release is at its tag" do
    When
    select(channel("rspock"), "--release", "1.2.0", "--allow-stale")

    Then
    raises(Dev::Cli::DeploySelector::AllowStaleWithReleaseError)
    @gh.calls.empty?
  end

  test "a --release that names no release, or no tag, is the source's own refusal: #{what}" do
    Given
    @gh.refuses(["release", "view"], with: "release not found")

    When
    select(channel("rspock"), "--release", version)

    Then
    raises(error_class)

    Where
    what                | version   | error_class
    "an uncut version"  | "9.9.9"   | Dev::Lifecycle::ReleaseArchives::NoReleaseError
    "not a version"     | "a b"     | Dev::Lifecycle::ReleaseTag::InvalidVersionError
  end

  test "--config picks among several artifacts of an accepted build; without it two candidates are a refusal naming both" do
    Given
    stamp("cellbound-3d-win64-dev")
    stamp("cellbound-3d-win64-release")
    chosen = select(channel("cellbound-3d-win64"), "--config", "release")

    When
    select(channel("cellbound-3d-win64"))

    Then
    chosen.shipments.map(&:name) == ["cellbound-3d-win64-release"]
    error = raises(Dev::Cli::DeploySelector::AmbiguousArtifactError)
    error.message == "'cellbound-3d-win64' has 2 artifacts in the store: cellbound-3d-win64-dev (1.2.0+3f2a1c9d8e7b), " \
                     "cellbound-3d-win64-release (1.2.0+3f2a1c9d8e7b) — --config chooses"
  end

  test "a positional narrows the accept set to the builds it spans that the channel accepts: #{words.inspect}" do
    Given "every client artifact present, and a channel accepting the release ones plus the server"
    stamp("cellbound-3d-win64-dev")
    stamp("cellbound-3d-win64-release")
    stamp("cellbound-3d-linux64-dev")
    stamp("cellbound-3d-linux64-release")
    stamp("cellbound-3d-server-linux64-dev")

    Expect
    select(channel("cellbound-3d-release", "cellbound-3d-server-dev"), *words).shipments.map(&:name) == selected

    Where
    words                                        | selected
    []                                           | ["cellbound-3d-win64-release", "cellbound-3d-linux64-release", "cellbound-3d-server-linux64-dev"]
    ["cellbound-3d"]                             | ["cellbound-3d-win64-release", "cellbound-3d-linux64-release"]
    ["cellbound-3d-linux64"]                     | ["cellbound-3d-linux64-release"]
    ["cellbound-3d-linux64-release"]             | ["cellbound-3d-linux64-release"]
    ["cellbound-3d-server"]                      | ["cellbound-3d-server-linux64-dev"]
    ["cellbound-3d", "--config", "release"]      | ["cellbound-3d-win64-release", "cellbound-3d-linux64-release"]
  end

  test "a build outside the accept set is refused, naming what the channel accepts; --force ships it" do
    Given
    stamp("cellbound-3d-win64-dev")
    forced = select(channel("cellbound-3d-release"), "cellbound-3d-win64-dev", "--force")

    When
    select(channel("cellbound-3d-release"), "cellbound-3d-win64-dev")

    Then
    forced.shipments.map(&:name) == ["cellbound-3d-win64-dev"]
    error = raises(Dev::Cli::DeploySelector::OutsideAcceptSetError)
    error.message == "'cellbound-3d-win64-dev' names no build channel 'staging' accepts " \
                     "(it accepts cellbound-3d-win64-release, cellbound-3d-linux64-release); --force ships it anyway"
  end

  test "--force widens a pattern to every build it spans; the config rule still applies per platform" do
    Given "a channel accepting only release; dev artifacts on both platforms"
    stamp("cellbound-3d-win64-dev")
    stamp("cellbound-3d-linux64-dev")

    Expect
    select(channel("cellbound-3d-release"), "cellbound-3d", "--force").shipments.map(&:name) == ["cellbound-3d-win64-dev", "cellbound-3d-linux64-dev"]
  end

  test "a missing artifact is refused with the package command that makes it: deploy never builds" do
    When
    select(channel("cellbound-3d-steamworks"))

    Then
    error = raises(Dev::Cli::DeploySelector::MissingArtifactError)
    error.message == "no artifact of 'cellbound-3d-steamworks-win64' in the store (cellbound-3d-steamworks-win64-release) — " \
                     "`dev package cellbound-3d-steamworks-win64-release` first; deploy never builds"
  end

  test "a stale artifact is refused unless --allow-stale, which ships it and reports it as stale" do
    Given "the win64 artifact from an older commit, the linux64 one from this one"
    stamp("cellbound-3d-win64-dev", state: MOVED_ON)
    stamp("cellbound-3d-linux64-dev")
    allowed = select(channel("cellbound-3d-dev"), "--allow-stale")

    When
    select(channel("cellbound-3d-dev"))

    Then
    allowed.shipments.map(&:name) == ["cellbound-3d-win64-dev", "cellbound-3d-linux64-dev"]
    allowed.stale.map(&:name) == ["cellbound-3d-win64-dev"]
    error = raises(Dev::Cli::DeploySelector::StaleArtifactError)
    error.message == "cellbound-3d-win64-dev (1.2.0+0000aaaa1111) was not packaged from a clean tree at this commit — " \
                     "`dev package` again, or --allow-stale to ship as is"
  end

  test "an artifact packaged from a dirty tree is stale even at the same commit" do
    Given
    stamp("rspock", state: Dev::Lifecycle::GitState.new(sha: CLEAN.sha, dirty: true))

    When
    select(channel("rspock"))

    Then
    raises Dev::Cli::DeploySelector::StaleArtifactError
  end

  test "the argv's own faults: #{fault}" do
    Given
    stamp("cellbound-3d-win64-dev")

    When
    select(channel("cellbound-3d-win64-dev"), *words)

    Then
    error = raises(error_class)
    error.message.include?(mention)

    Where
    fault                             | words                      | error_class                                      | mention
    "two positionals"                 | ["cellbound-3d", "rspock"] | Dev::Cli::DeploySelector::TooManyBuildsError     | "one build at a time"
    "--force with no build named"     | ["--force"]                | Dev::Cli::DeploySelector::ForceWithoutBuildError | "name it"
    "--config outside the accept set" | ["--config", "release"]    | Dev::Cli::DeploySelector::NoAcceptedConfigError  | "no build of 'cellbound-3d-win64-dev' has config 'release'"
    "--config off the id set"         | ["--config", "shipping"]   | Dev::Lifecycle::UnknownConfigError               | "shipping"
    "a positional naming no target"   | ["snappy"]                 | Dev::Lifecycle::BuildPattern::UnknownTargetError | "snappy"
  end
end

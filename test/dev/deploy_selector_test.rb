# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/flag_vocabulary"
require "dev/command"
require "dev/deploy_selector"
require "dev/lifecycle"
require "support/lifecycle_fixtures"
require "fileutils"
require "pathname"
require "time"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::DeploySelectorTest < Minitest::Test
  include LifecycleFixtures

  NOON = Time.utc(2026, 11, 4, 12, 0, 0)
  CLEAN = Dev::Lifecycle::GitState.new(sha: "3f2a1c9d8e7b", dirty: false)
  MOVED_ON = Dev::Lifecycle::GitState.new(sha: "0000aaaa1111", dirty: false)

  # A node declaring exactly the selector's flags, so the words parse the
  # way the verb's argv does.
  class SelectingVerb < Dev::LifecycleCommand
    Env = type_member { { fixed: String } }

    def desc = "selects"

    def flags = Dev::DeploySelector::FLAGS

    def before(args:, context:) = Dev::Dispatch::Outcome::Done.new

    def seam(env, context:); end

    def after(env, context:); end
  end

  def setup
    @root = Pathname(Dir.mktmpdir("deploy-selector-"))
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  def store = Dev::Lifecycle::Store.new(project_name: "cellbound-3d", targets: all_targets, data_root: @root.to_s)

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
    Dev::DeploySelector.new(channel:, targets: all_targets, store:).select(parsed_args(SelectingVerb.new, words), state:)
  end

  test "bare: one artifact per accepted (target, platform), in accept order, the config decided by what the store holds" do
    Given "a channel over the client on both platforms and the gem; the store holds one config of each client platform"
    stamp("cellbound-3d-win64-dev")
    stamp("cellbound-3d-linux64-release")
    stamp("rspock")

    When
    selection = select(channel("cellbound-3d", "rspock"))

    Then "and a selection from the store is for the testing track: working artifacts never touch live"
    selection.artifacts.map(&:name) == ["cellbound-3d-win64-dev", "cellbound-3d-linux64-release", "rspock"]
    selection.stale == []
    selection.track == Dev::Lifecycle::Track::Testing
  end

  test "--config picks among several artifacts of an accepted build; without it two candidates are a refusal naming both" do
    Given
    stamp("cellbound-3d-win64-dev")
    stamp("cellbound-3d-win64-release")
    chosen = select(channel("cellbound-3d-win64"), "--config", "release")

    When
    select(channel("cellbound-3d-win64"))

    Then
    chosen.artifacts.map(&:name) == ["cellbound-3d-win64-release"]
    error = raises(Dev::DeploySelector::AmbiguousArtifactError)
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
    select(channel("cellbound-3d-release", "cellbound-3d-server-dev"), *words).artifacts.map(&:name) == selected

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
    forced.artifacts.map(&:name) == ["cellbound-3d-win64-dev"]
    error = raises(Dev::DeploySelector::OutsideAcceptSetError)
    error.message == "'cellbound-3d-win64-dev' names no build channel 'staging' accepts " \
                     "(it accepts cellbound-3d-win64-release, cellbound-3d-linux64-release); --force ships it anyway"
  end

  test "--force widens a pattern to every build it spans; the config rule still applies per platform" do
    Given "a channel accepting only release; dev artifacts on both platforms"
    stamp("cellbound-3d-win64-dev")
    stamp("cellbound-3d-linux64-dev")

    Expect
    select(channel("cellbound-3d-release"), "cellbound-3d", "--force").artifacts.map(&:name) == ["cellbound-3d-win64-dev", "cellbound-3d-linux64-dev"]
  end

  test "a missing artifact is refused with the package command that makes it: deploy never builds" do
    When
    select(channel("cellbound-3d-steamworks"))

    Then
    error = raises(Dev::DeploySelector::MissingArtifactError)
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
    allowed.artifacts.map(&:name) == ["cellbound-3d-win64-dev", "cellbound-3d-linux64-dev"]
    allowed.stale.map(&:name) == ["cellbound-3d-win64-dev"]
    error = raises(Dev::DeploySelector::StaleArtifactError)
    error.message == "cellbound-3d-win64-dev (1.2.0+0000aaaa1111) was not packaged from a clean tree at this commit — " \
                     "`dev package` again, or --allow-stale to ship as is"
  end

  test "an artifact packaged from a dirty tree is stale even at the same commit" do
    Given
    stamp("rspock", state: Dev::Lifecycle::GitState.new(sha: CLEAN.sha, dirty: true))

    When
    select(channel("rspock"))

    Then
    raises Dev::DeploySelector::StaleArtifactError
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
    fault                               | words                                       | error_class                                         | mention
    "two positionals"                   | ["cellbound-3d", "rspock"]                  | Dev::DeploySelector::TooManyBuildsError             | "one build at a time"
    "--force with no build named"       | ["--force"]                                 | Dev::DeploySelector::ForceWithoutBuildError         | "name it"
    "--config outside the accept set"   | ["--config", "release"]                     | Dev::DeploySelector::NoAcceptedConfigError          | "no build of 'cellbound-3d-win64-dev' has config 'release'"
    "--config off the id set"           | ["--config", "shipping"]                    | Dev::Lifecycle::UnknownConfigError                  | "shipping"
    "a positional naming no target"     | ["snappy"]                                  | Dev::Lifecycle::BuildPattern::UnknownTargetError    | "snappy"
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/deploy_all_command"
require "dev/builtins/deploy_command"
require "dev/builtins/deploy_status_command"
require "dev/deploy_selector"
require "dev/dispatch_resolver"
require "dev/enrolled_runner_lookup"
require "dev/host_environment"
require "dev/host_rule"
require "dev/lifecycle"
require "dev/lifecycle_executor"
require "dev/placement"
require "dev/settings"
require "support/fake_gh"
require "support/recording_publisher"
require "support/release_fixtures"
require "support/scripted_remote"
require "fileutils"
require "open3"
require "pathname"
require "stringio"
require "tmpdir"

# The fan-out end to end through the LifecycleExecutor: two channels over
# a real project, a release on the scripted forge, the ledger over the
# same FakeGh. Each channel is the real DeployCommand, so what is under
# test here is the orchestration — order, the words each channel gets,
# where a refusal stops — not a channel's own behaviour.
transform!(RSpock::AST::Transformation)
class Dev::Builtins::DeployAllCommandTest < Minitest::Test
  include SorbetHelper
  include ReleaseFixtures

  # The repo has no enrolled runner online.
  class NoneEnrolled < Dev::EnrolledRunnerLookup
    def available = nil
  end

  REPO = "d3mlabs/cellbound-3d"
  DEPLOYMENTS = "repos/#{REPO}/deployments".freeze

  def setup
    @root = Pathname(Dir.mktmpdir("deploy-all-"))
    @project = @root / "project"
    @project.mkpath
    (@project / "stage.sh").write(<<~SH)
      #!/bin/sh
      set -eu
      echo "$DEV_CHANNEL $DEV_TRACK $DEV_BUILD $DEV_RELEASE_VERSION" >> "#{@root}/shipped"
    SH
    Open3.capture2e("git", "-C", @project.to_s, "init", "-q")
    @out = StringIO.new
    @gh = FakeGh.new(root: @project)
    @ui = typed_mock(Dev::Cli::Ui)
    @steam = RecordingPublisher.new
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  def shipped = (@root / "shipped").file? ? (@root / "shipped").readlines.map(&:chomp) : []
  def targets = [client_target, gem_target]
  def store = Dev::Lifecycle::Store.new(project_name: "cellbound-3d", targets:, data_root: (@root / "data").to_s)
  def build(name) = Dev::Lifecycle::Build.parse(name, targets)

  # Script the forge to accept deployments and their statuses, as ids 41, 42, …
  def forge_accepts(count)
    @gh.resolving(REPO)
    count.times do |i|
      id = 41 + i
      @gh.answers(["api", "-X", "POST", "--input", "-", DEPLOYMENTS], with: { "id" => id, "ref" => "x", "created_at" => "2026-11-05T17:02:11Z" })
      @gh.answers(["api", "-X", "POST", "--input", "-", "#{DEPLOYMENTS}/#{id}/statuses"], with: { "state" => "x" })
    end
  end

  def channels
    {
      "steam" => Dev::Lifecycle::Channel.new(
        name: "steam", desc: "Steam depots", accepts: [Dev::Lifecycle::BuildPattern.parse("cellbound-3d-release", targets)],
        publisher: Dev::Lifecycle::PublisherSpec::Integration.new(name: "steam"),
      ),
      "rubygems" => Dev::Lifecycle::Channel.new(
        name: "rubygems", desc: "gem push", accepts: [Dev::Lifecycle::BuildPattern.parse("rspock", targets)],
        publisher: Dev::Lifecycle::PublisherSpec::Script.new(command: "sh ./stage.sh"),
      ),
    }
  end

  def command
    host_rule = Dev::HostRule.new(host_environment: Dev::HostEnvironment.new(path: (@root / "no-marker").to_s), inside_container: false)
    settings = Dev::Settings.new(config_path: (@root / "config.yml").to_s, system_config_path: (@root / "none.yml").to_s)
    remote = ScriptedRemote.new(root: @project, ui: @ui)
    resolver = Dev::DispatchResolver.new(host_rule:, remotes: remote.remotes, enrolled: NoneEnrolled.new, settings:, inside_job: false)
    deployments = Dev::Lifecycle::GithubDeployments.new(gh: @gh)
    release_archives = Dev::Lifecycle::ReleaseArchives.new(releases: Dev::Lifecycle::GithubReleases.new(gh: @gh), store:, targets:)
    ports = Dev::Lifecycle::Ports.new(project_root: @project, publishers: { "steam" => @steam })
    verbs = channels.to_h do |name, channel|
      verb = Dev::Builtins::DeployCommand.new(
        channel:, selector: Dev::DeploySelector.new(channel:, targets:, store:, release_archives:),
        ports:, store:, resolver:, placement: Dev::Placement::Host.new, deployments:, out: @out, err: StringIO.new,
      )
      [name, verb]
    end
    status = Dev::Builtins::DeployStatusCommand.new(channels: channels.values, deployments:, out: @out)
    Dev::Builtins::DeployAllCommand.new(channels: verbs, status:, out: @out)
  end

  def context
    Dev::ExecutionContext.new(ui: @ui, project: Dev::ProjectContext.new(name: "cellbound-3d", root: @project))
  end

  def execute(verb, *words)
    Dev::LifecycleExecutor.new.execute(verb, args: parsed_args(verb, words), context:)
  end

  test "`dev deploy --release V` ships the release to every channel in turn, each as `deploy <channel> --release V`, headed and summed up" do
    Given "a release carrying what both channels accept; the forge looked up once per channel"
    release_on(@gh, { "cellbound-3d-win64-release" => "win", "cellbound-3d-linux64-release" => "linux", "rspock" => "gem" }, lookups: 2)
    forge_accepts(2)
    dir = store.release_dir(Dev::Lifecycle::ReleaseTag.new("1.2.0"))

    When
    execute(command, "--release", "1.2.0")

    Then "steam got the client release archives, rubygems the gem, both live and recorded against the tag; release.json was read per channel, each archive downloaded once"
    @steam.calls.map { |call| [call.track, call.shipments.map(&:name)] } == [[Dev::Lifecycle::Track::Live, ["cellbound-3d-win64-release", "cellbound-3d-linux64-release"]]]
    shipped == ["rubygems live rspock 1.2.0"]
    @gh.posted.select { |body| body.key?("ref") }.map { |body| [body["environment"], body["ref"], body["production_environment"]] } ==
      [["steam", "v1.2.0", true], ["rubygems", "v1.2.0", true]]
    @gh.downloaded("v1.2.0") == [["release.json"], ["cellbound-3d-win64-release-1.2.0.zip", "cellbound-3d-linux64-release-1.2.0.zip"], ["release.json"], ["rspock-1.2.0.zip"]]
    @out.string == <<~OUT
      deploy steam --release 1.2.0
      deployed cellbound-3d-win64-release (1.2.0+3f2a1c9d8e7b) → steam (live): #{dir / "cellbound-3d-win64-release-1.2.0.zip"}
      deployed cellbound-3d-linux64-release (1.2.0+3f2a1c9d8e7b) → steam (live): #{dir / "cellbound-3d-linux64-release-1.2.0.zip"}
      recorded as GitHub Deployment #41 (live track) → https://github.com/#{REPO}/deployments/steam
      deploy rubygems --release 1.2.0
      deployed rspock (1.2.0+3f2a1c9d8e7b) → rubygems (live): #{dir / "rspock-1.2.0.zip"}
      recorded as GitHub Deployment #42 (live track) → https://github.com/#{REPO}/deployments/rubygems
      v1.2.0 shipped to 2 channels: steam, rubygems
    OUT
  end

  test "--dry-run reaches every channel: the fan-out is a rehearsal, nothing ships or is recorded" do
    Given
    release_on(@gh, { "cellbound-3d-win64-release" => "win", "cellbound-3d-linux64-release" => "linux", "rspock" => "gem" }, lookups: 2)

    When
    execute(command, "--dry-run", "--release", "1.2.0")

    Then
    @steam.calls == []
    shipped == []
    @gh.posted == []
    @out.string.lines.first == "deploy steam --release 1.2.0 --dry-run\n"
    @out.string.lines.last == "v1.2.0 would ship to 2 channels: steam, rubygems\n"
    @out.string.include?("would deploy rspock (1.2.0+3f2a1c9d8e7b) → rubygems (live)")
  end

  test "the first channel that refuses ends the fan-out there: the earlier ones shipped, the later ones were not reached" do
    Given "a release carrying nothing rubygems accepts"
    release_on(@gh, { "cellbound-3d-win64-release" => "win", "cellbound-3d-linux64-release" => "linux" }, lookups: 2)
    forge_accepts(1)

    When
    execute(command, "--release", "1.2.0")

    Then
    error = raises Dev::DeploySelector::NotInReleaseError
    error.message.start_with?("v1.2.0 carries no archive of 'rspock'")
    @steam.calls.size == 1
    shipped == []
    @out.string.lines.last == "deploy rubygems --release 1.2.0\n"
  end

  test "bare `dev deploy` is refused with the verb's shape: the store ships one channel at a time" do
    When
    execute(command)

    Then
    error = raises Dev::Builtins::DeployAllCommand::NoChannelError
    error.message == "deploy ships to one channel at a time from the store — `dev deploy <channel> [BUILD]` (channels: steam, rubygems); " \
                     "only `dev deploy --release <version>` ships to every channel"
    @gh.calls == []
  end

  test "a word that names no channel is refused by name, naming the channels: #{words.inspect}" do
    When
    execute(command, *words)

    Then
    error = raises Dev::Builtins::DeployAllCommand::UnknownChannelError
    error.message == "'itch' is not a channel (channels: steam, rubygems); `dev deploy <channel> [BUILD]`"

    Where
    words                           | _
    ["itch"]                        | nil
    ["itch", "--release", "1.2.0"]  | nil
  end

  test "a --release that names no tag is the tag's refusal" do
    When
    execute(command, "--release", "a b")

    Then
    raises Dev::Lifecycle::ReleaseTag::InvalidVersionError
  end

  test "the node's traits: the channels then status as children, the shared flags plus --runner, the lifecycle category" do
    Given
    verb = command

    Expect
    verb.children.keys == ["steam", "rubygems", "status"]
    verb.children.values.map(&:class) == [Dev::Builtins::DeployCommand, Dev::Builtins::DeployCommand, Dev::Builtins::DeployStatusCommand]
    verb.flags.map(&:name) == ["--release", "--dry-run", "--runner"]
    verb.category == Dev::Command::Category::Lifecycle
    verb.desc.include?("`deploy --release V` with no channel ships the release to every channel in turn")
    verb.listing.nil?
    verb.placement.nil?
  end
end

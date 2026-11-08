# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/deploy_command"
require "dev/deploy_selector"
require "dev/dispatch"
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
require "time"
require "tmpdir"

# The verb end to end through the LifecycleExecutor: a real git repo as
# the project (the staleness rule reads the tree), artifacts stamped into
# a real store in a temp data root, a real `run:` script recording what
# it was handed, and the deployment ledger over a scripted gh (FakeGh —
# the forge is the one boundary not reproducible here). The channel's
# protocol is placed on the host; the remote cases force the dispatch
# with `--runner` over a scripted forge (ScriptedRemote).
transform!(RSpock::AST::Transformation)
class Dev::Builtins::DeployCommandTest < Minitest::Test
  include SorbetHelper
  include ReleaseFixtures

  # The repo has no enrolled runner online.
  class NoneEnrolled < Dev::EnrolledRunnerLookup
    def available = nil
  end

  PLATFORM = Dev::Lifecycle::Platform
  CONFIG = Dev::Lifecycle::Config
  NOON = Time.utc(2026, 11, 4, 12, 0, 0)
  REPO = "d3mlabs/cellbound-3d"
  DEPLOYMENTS = "repos/#{REPO}/deployments".freeze

  def setup
    @root = Pathname(Dir.mktmpdir("deploy-command-"))
    @project = @root / "project"
    @project.mkpath
    (@project / "stage.sh").write(<<~SH)
      #!/bin/sh
      set -eu
      echo "$DEV_CHANNEL $DEV_TRACK $DEV_BUILD $DEV_BUILD_ID $DEV_SHA $DEV_DIRTY $DEV_ARTIFACT" >> "#{@root}/shipped"
      touch "$DEV_SCRATCH/left-behind"
    SH
    git("init", "-q")
    git("add", ".")
    commit("one")
    @out = StringIO.new
    @err = StringIO.new
    @gh = FakeGh.new(root: @project)
    @ui = typed_mock(Dev::Cli::Ui)
    @remote = ScriptedRemote.new(root: @project, ui: @ui)
  end

  # Script the forge to accept one deployment and its status, as ids 41, 42, …
  def forge_accepts(count = 1)
    @gh.resolving(REPO)
    count.times do |i|
      id = 41 + i
      @gh.answers(["api", "-X", "POST", "--input", "-", DEPLOYMENTS], with: { "id" => id, "ref" => "x", "created_at" => "2026-11-05T17:02:11Z" })
      @gh.answers(["api", "-X", "POST", "--input", "-", "#{DEPLOYMENTS}/#{id}/statuses"], with: { "state" => "x" })
    end
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  def git(*args) = Open3.capture2e("git", "-C", @project.to_s, "-c", "user.name=t", "-c", "user.email=t@t", *args)
  def commit(message) = git("commit", "-q", "--allow-empty", "-m", message)
  def head = Open3.capture2("git", "-C", @project.to_s, "rev-parse", "--short=12", "HEAD").first.strip
  def shipped = (@root / "shipped").file? ? (@root / "shipped").readlines.map(&:chomp) : []

  def client
    Dev::Lifecycle::Target.new(
      name: "cellbound-3d", desc: "Client", platforms: [PLATFORM::Win64, PLATFORM::Linux64], configs: [CONFIG::Development, CONFIG::Release],
    )
  end

  def targets = [client, gem_target]
  def store = Dev::Lifecycle::Store.new(project_name: "cellbound-3d", targets: targets, data_root: (@root / "data").to_s)
  def build(name) = Dev::Lifecycle::Build.parse(name, targets)

  def release_archives
    Dev::Lifecycle::ReleaseArchives.new(releases: Dev::Lifecycle::GithubReleases.new(gh: @gh), store:, targets:)
  end

  def channel(*patterns)
    Dev::Lifecycle::Channel.new(
      name: "staging", desc: "rsync to the gamebox",
      accepts: patterns.map { |name| Dev::Lifecycle::BuildPattern.parse(name, targets) },
      publisher: Dev::Lifecycle::PublisherSpec::Script.new(command: "sh ./stage.sh"),
    )
  end

  def stamp(build_name, sha: head, dirty: false)
    state = Dev::Lifecycle::GitState.new(sha:, dirty:)
    artifact = store.stamp(
      Dev::Lifecycle::Manifest::Artifact.new(
        stamp: Dev::Lifecycle::Manifest::Stamp.now(dev_version: "0.7.2", now: NOON),
        build: build(build_name), state:, packaged_at: NOON, builder: "script", builder_version: nil,
        build_id: Dev::Lifecycle::BuildId.new("1.2.3+#{sha}"), archive: "#{build_name}.zip", archive_sha256: "ab" * 32,
      ),
    )
    artifact.archive.write("zip")
    artifact
  end

  def steam_channel
    Dev::Lifecycle::Channel.new(
      name: "steam", desc: "Steam depots",
      accepts: [Dev::Lifecycle::BuildPattern.parse("cellbound-3d-release", targets)],
      publisher: Dev::Lifecycle::PublisherSpec::Integration.new(name: "steam"),
    )
  end

  def command(channel = self.channel("cellbound-3d-dev", "rspock"), placement: Dev::Placement::Host.new, publishers: {})
    host_rule = Dev::HostRule.new(host_environment: Dev::HostEnvironment.new(path: (@root / "no-marker").to_s), inside_container: false)
    settings = Dev::Settings.new(config_path: (@root / "config.yml").to_s, system_config_path: (@root / "none.yml").to_s)
    resolver = Dev::DispatchResolver.new(
      host_rule: host_rule, remotes: @remote.remotes, enrolled: NoneEnrolled.new, settings: settings, inside_job: false,
    )
    Dev::Builtins::DeployCommand.new(
      channel: channel,
      selector: Dev::DeploySelector.new(channel: channel, targets: targets, store: store, release_archives:),
      ports: Dev::Lifecycle::Ports.new(project_root: @project, publishers:),
      store: store,
      resolver: resolver,
      placement: placement,
      deployments: Dev::Lifecycle::GithubDeployments.new(gh: @gh),
      out: @out,
      err: @err,
    )
  end

  def context
    Dev::ExecutionContext.new(ui: @ui, project: Dev::ProjectContext.new(name: "cellbound-3d", root: @project))
  end

  def execute(verb, *words)
    Dev::LifecycleExecutor.new.execute(verb, args: parsed_args(verb, words), context: context)
  end

  test "bare `dev deploy staging` ships one artifact per accepted platform through the run: line on the testing track, reports each, and records the deploy on the forge" do
    Given "a current artifact of every accepted build, and a forge that takes the record"
    win64 = stamp("cellbound-3d-win64-dev")
    linux64 = stamp("cellbound-3d-linux64-dev")
    gem = stamp("rspock")
    forge_accepts

    When
    execute(command)

    Then "the script ran once per archive with the channel, the track, the build and the manifest's keys, in the channel's scratch; " \
         "the verb reported each and the record; the record is one GitHub Deployment: the channel as environment, the commit as ref, " \
         "the builds and the testing track as payload, a success status carrying the run: line as the receipt"
    shipped == [
      "staging testing cellbound-3d-win64-dev 1.2.3+#{head} #{head} false #{win64.archive}",
      "staging testing cellbound-3d-linux64-dev 1.2.3+#{head} #{head} false #{linux64.archive}",
      "staging testing rspock 1.2.3+#{head} #{head} false #{gem.archive}",
    ]
    (store.root / ".staging" / "left-behind").file?
    @out.string == <<~OUT
      deployed cellbound-3d-win64-dev (1.2.3+#{head}) → staging (testing): #{win64.archive}
      deployed cellbound-3d-linux64-dev (1.2.3+#{head}) → staging (testing): #{linux64.archive}
      deployed rspock (1.2.3+#{head}) → staging (testing): #{gem.archive}
      recorded as GitHub Deployment #41 (testing track) → https://github.com/#{REPO}/deployments/staging
    OUT
    @gh.posted == [
      {
        "ref" => head,
        "environment" => "staging",
        "description" => "dev deploy staging: cellbound-3d-win64-dev, cellbound-3d-linux64-dev, rspock",
        "payload" => {
          "schema" => 1,
          "track" => "testing",
          "builds" => [
            { "build" => "cellbound-3d-win64-dev", "build_id" => "1.2.3+#{head}" },
            { "build" => "cellbound-3d-linux64-dev", "build_id" => "1.2.3+#{head}" },
            { "build" => "rspock", "build_id" => "1.2.3+#{head}" },
          ],
        },
        "auto_merge" => false,
        "required_contexts" => [],
        "production_environment" => false,
      },
      { "state" => "success", "description" => "run: sh ./stage.sh" },
    ]
  end

  test "a channel naming the lock's publisher hands it the selection, the testing track and its scratch — the protocol is the integration's (dev#422)" do
    Given "a current release artifact, a lock contributing steam, and a forge that takes the record"
    steam = RecordingPublisher.new
    win64 = stamp("cellbound-3d-win64-release")
    linux64 = stamp("cellbound-3d-linux64-release")
    forge_accepts

    When
    execute(command(steam_channel, publishers: { "steam" => steam }))

    Then "and the record's receipt is the integration's, not a run: line"
    steam.calls.size == 1
    steam.calls.first.shipments == [win64, linux64].map { |artifact| Dev::Lifecycle::Shipment.of_artifact(artifact) }
    steam.calls.first.channel == steam_channel
    steam.calls.first.track == Dev::Lifecycle::Track::Testing
    steam.calls.first.scratch == store.root / ".steam"
    shipped == []
    @out.string == <<~OUT
      deployed cellbound-3d-win64-release (1.2.3+#{head}) → steam (testing): #{win64.archive}
      deployed cellbound-3d-linux64-release (1.2.3+#{head}) → steam (testing): #{linux64.archive}
      recorded as GitHub Deployment #41 (testing track) → https://github.com/#{REPO}/deployments/steam
    OUT
    @gh.posted.first["environment"] == "steam"
    @gh.posted.last == { "state" => "success", "description" => "recorded cellbound-3d-win64-release, cellbound-3d-linux64-release" }
  end

  test "--dry-run selects and reports, running no protocol and recording nothing" do
    Given
    stamp("cellbound-3d-win64-dev")
    stamp("cellbound-3d-linux64-dev")
    stamp("rspock")

    When
    execute(command, "rspock", "--dry-run")

    Then
    shipped == []
    !(store.root / ".staging").exist?
    @out.string == "would deploy rspock (1.2.3+#{head}) → staging (testing): #{store.artifact(build("rspock")).archive}\n"
    @gh.calls == []
  end

  test "a seam that raises is recorded as a failed deploy carrying the error, then the error bubbles" do
    Given "a script that refuses, and a forge that takes the record"
    (@project / "stage.sh").write("exit 7\n")
    git("add", ".")
    commit("two")
    stamp("rspock")
    forge_accepts

    When
    execute(command, "rspock")

    Then
    raises Dev::Lifecycle::ScriptPublisher::DeployScriptFailedError
    @gh.posted.first.slice("ref", "environment", "payload") == {
      "ref" => head, "environment" => "staging",
      "payload" => { "schema" => 1, "track" => "testing", "builds" => [{ "build" => "rspock", "build_id" => "1.2.3+#{head}" }] },
    }
    @gh.posted.last == { "state" => "failure", "description" => "deploy script `sh ./stage.sh` for rspock → staging exited 7" }
    @out.string == ""
    @err.string == ""
  end

  test "a failure record the forge refuses is reported on stderr and never replaces the protocol's error" do
    Given "a script that refuses, and no repo for the forge to record against"
    (@project / "stage.sh").write("exit 7\n")
    git("add", ".")
    commit("two")
    stamp("rspock")
    @gh.refuses(["repo", "view"], with: "no git remotes found")

    When
    execute(command, "rspock")

    Then
    raises Dev::Lifecycle::ScriptPublisher::DeployScriptFailedError
    @err.string.start_with?("dev: the failed deploy staging was not recorded: could not resolve the repo")
  end

  test "a deploy the forge will not record is reported as shipped but unrecorded, after the shipped lines" do
    Given "a forge that has no such ref"
    gem = stamp("rspock")
    @gh.resolving(REPO).refuses(["api", "-X", "POST"], with: "HTTP 422: No ref found for: #{head}")

    When
    execute(command, "rspock")

    Then
    error = raises Dev::Builtins::DeployCommand::NotRecordedError
    error.message.start_with?("deployed to staging, but the deploy was not recorded: the deployment ledger could not be written")
    error.message.include?("No ref found")
    shipped == ["staging testing rspock 1.2.3+#{head} #{head} false #{gem.archive}"]
    @out.string == "deployed rspock (1.2.3+#{head}) → staging (testing): #{gem.archive}\n"
  end

  test "artifacts of two commits shipped together under --allow-stale are two records, one per ref" do
    Given "a stale gem artifact beside a current client one"
    stale = stamp("rspock")
    commit("two")
    stamp("cellbound-3d-win64-dev")
    stamp("cellbound-3d-linux64-dev")
    forge_accepts(2)

    When
    execute(command, "--allow-stale")

    Then
    @gh.posted.select { |body| body.key?("ref") }.map { |body| [body["ref"], body["payload"]["builds"].map { |b| b["build"] }] } == [
      [head, ["cellbound-3d-win64-dev", "cellbound-3d-linux64-dev"]],
      [stale.manifest.state.sha, ["rspock"]],
    ]
    @out.string.end_with?("recorded as GitHub Deployment #41, #42 (testing track) → https://github.com/#{REPO}/deployments/staging\n")
  end

  test "a stale artifact is refused before the protocol runs" do
    Given "an artifact packaged at the previous commit"
    stamp("rspock")
    commit("two")

    When
    execute(command, "rspock")

    Then
    raises Dev::DeploySelector::StaleArtifactError
    shipped == []
    @out.string == ""
  end

  test "--allow-stale ships a stale artifact and says so" do
    Given "an artifact packaged at the previous commit"
    stale = stamp("rspock")
    commit("two")
    forge_accepts

    When
    execute(command, "rspock", "--allow-stale")

    Then "and the record's ref is the commit the artifact came from, not the tree's"
    shipped == ["staging testing rspock 1.2.3+#{stale.manifest.state.sha} #{stale.manifest.state.sha} false #{stale.archive}"]
    @out.string.start_with?("deployed rspock (1.2.3+#{stale.manifest.state.sha}) → staging (testing): #{stale.archive} — stale, shipped under --allow-stale\n")
    @gh.posted.first["ref"] == stale.manifest.state.sha
  end

  test "a missing artifact is refused before the protocol runs: deploy never builds" do
    Given "the win64 artifact only"
    stamp("cellbound-3d-win64-dev")

    When
    execute(command)

    Then
    error = raises Dev::DeploySelector::MissingArtifactError
    error.message.include?("`dev package cellbound-3d-linux64-dev` first")
    shipped == []
  end

  test "the protocol's failure surfaces as the script's, naming the archive it refused" do
    Given
    (@project / "stage.sh").write("exit 7\n")
    git("add", ".")
    commit("two")
    stamp("rspock")
    forge_accepts

    When
    execute(command, "rspock")

    Then
    error = raises Dev::Lifecycle::ScriptPublisher::DeployScriptFailedError
    error.message == "deploy script `sh ./stage.sh` for rspock → staging exited 7"
    @out.string == ""
  end

  test "a channel whose protocol has no placement bound is refused by name before the store is read" do
    When
    execute(command(placement: nil), "rspock")

    Then
    error = raises Dev::Builtins::DeployCommand::UnboundChannelError
    error.message.include?("`deploy staging` has no environment bound")
  end

  test "`--runner` sends the verb to the label re-spelled as given — the channel, the build, the selection flags — and the host selects from its own store: nothing is read, shipped or recorded here" do
    Given "no artifact in this store at all"
    @remote.install_workflow
    @ui.expects(:print_remote_crossing).with(runner: "gamebox", snapshot: ScriptedRemote::SHA[0, 12])

    When
    execute(command, "rspock", "--runner", "gamebox", "--allow-stale", "--dry-run", "--config", "release", "--release", "1.2.0")

    Then "the words in declared order, `--runner` left behind; no MissingArtifactError, since the host's store is the one that counts"
    @remote.dispatched_verbs == "deploy staging rspock --config release --release 1.2.0 --allow-stale --dry-run"
    @remote.sync.synced == ["gamebox"]
    shipped == []
    @gh.calls == []
    @out.string == ""
  end

  test "a channel whose protocol has no placement bound is refused even under `--runner`" do
    When
    execute(command(placement: nil), "rspock", "--runner", "gamebox")

    Then
    raises Dev::Builtins::DeployCommand::UnboundChannelError
    @remote.dispatched_verbs.nil?
  end

  # The release half: a cut release on the scripted forge, the script
  # recording what a release deploy tells it instead of the store's keys.
  def release_script
    (@project / "stage.sh").write(<<~SH)
      #!/bin/sh
      set -eu
      echo "$DEV_CHANNEL $DEV_TRACK $DEV_BUILD $DEV_BUILD_ID $DEV_RELEASE_VERSION $DEV_SHA ${DEV_DIRTY:-unset} ${DEV_PACKAGED_AT:-unset} $DEV_ARTIFACT" >> "#{@root}/shipped"
    SH
  end

  test "`--release V` ships the release's archives — downloaded into the store's .releases/<tag>/, verified — on the live track, telling the script the version, and records the deploy against the tag as a production deployment" do
    Given "a release of the dev client and the gem, and a store holding nothing"
    release_script
    release_on(@gh, { "cellbound-3d-win64-dev" => "win", "cellbound-3d-linux64-dev" => "linux", "rspock" => "gem" })
    forge_accepts
    dir = store.release_dir(Dev::Lifecycle::ReleaseTag.new("1.2.0"))

    When
    execute(command, "--release", "1.2.0")

    Then "the script saw the live track, the release's version and the tag's short sha, and none of the store's keys"
    shipped == [
      "staging live cellbound-3d-win64-dev 1.2.0+3f2a1c9d8e7b 1.2.0 3f2a1c9d8e7b unset unset #{dir / "cellbound-3d-win64-dev-1.2.0.zip"}",
      "staging live cellbound-3d-linux64-dev 1.2.0+3f2a1c9d8e7b 1.2.0 3f2a1c9d8e7b unset unset #{dir / "cellbound-3d-linux64-dev-1.2.0.zip"}",
      "staging live rspock 1.2.0+3f2a1c9d8e7b 1.2.0 3f2a1c9d8e7b unset unset #{dir / "rspock-1.2.0.zip"}",
    ]
    (dir / "rspock-1.2.0.zip").read == "gem"
    @out.string == <<~OUT
      deployed cellbound-3d-win64-dev (1.2.0+3f2a1c9d8e7b) → staging (live): #{dir / "cellbound-3d-win64-dev-1.2.0.zip"}
      deployed cellbound-3d-linux64-dev (1.2.0+3f2a1c9d8e7b) → staging (live): #{dir / "cellbound-3d-linux64-dev-1.2.0.zip"}
      deployed rspock (1.2.0+3f2a1c9d8e7b) → staging (live): #{dir / "rspock-1.2.0.zip"}
      recorded as GitHub Deployment #41 (live track) → https://github.com/#{REPO}/deployments/staging
    OUT
    @gh.posted.first.slice("ref", "environment", "production_environment") == { "ref" => "v1.2.0", "environment" => "staging", "production_environment" => true }
    @gh.posted.first["payload"] == {
      "schema" => 1, "track" => "live",
      "builds" => [
        { "build" => "cellbound-3d-win64-dev", "build_id" => "1.2.0+3f2a1c9d8e7b" },
        { "build" => "cellbound-3d-linux64-dev", "build_id" => "1.2.0+3f2a1c9d8e7b" },
        { "build" => "rspock", "build_id" => "1.2.0+3f2a1c9d8e7b" },
      ],
    }
  end

  test "`--release V` hands an integration's publisher the release's shipments on the live track" do
    Given
    steam = RecordingPublisher.new
    release_on(@gh, { "cellbound-3d-win64-release" => "win", "cellbound-3d-linux64-release" => "linux" })
    forge_accepts

    When
    execute(command(steam_channel, publishers: { "steam" => steam }), "--release", "1.2.0")

    Then
    steam.calls.first.track == Dev::Lifecycle::Track::Live
    steam.calls.first.shipments.map(&:provenance).uniq == [Dev::Lifecycle::Provenance::Release.new(tag: Dev::Lifecycle::ReleaseTag.new("1.2.0"), sha: RELEASE_SHA)]
    steam.calls.first.shipments.map(&:name) == ["cellbound-3d-win64-release", "cellbound-3d-linux64-release"]
    @gh.posted.first["ref"] == "v1.2.0"
  end

  test "`--release V` with a corrupted asset ships nothing and records nothing" do
    Given "a forge serving other bytes than release.json digests"
    release_on(@gh, { "rspock" => "gem" }, manifest: release_manifest({ "rspock" => "what the cut digested" }))

    When
    execute(command, "rspock", "--release", "1.2.0")

    Then
    raises Dev::Lifecycle::ReleaseArchives::ChecksumMismatchError
    shipped == []
    @gh.posted == []
    @out.string == ""
  end

  test "`--release V --dry-run` downloads and verifies, reports what would ship on the live track, and runs no protocol" do
    Given
    release_on(@gh, { "rspock" => "gem" })
    dir = store.release_dir(Dev::Lifecycle::ReleaseTag.new("1.2.0"))

    When
    execute(command, "rspock", "--release", "1.2.0", "--dry-run")

    Then
    shipped == []
    @out.string == "would deploy rspock (1.2.0+3f2a1c9d8e7b) → staging (live): #{dir / "rspock-1.2.0.zip"}\n"
    (dir / "rspock-1.2.0.zip").file?
    @gh.posted == []
  end

  test "the verb's traits: the channel's desc, the selector's flags plus --dry-run and --runner, its placement, the accept set and protocol as details" do
    Given
    verb = command

    Expect
    verb.category == Dev::Command::Category::Lifecycle
    verb.desc == "rsync to the gamebox"
    verb.flags.map(&:name) == ["--config", "--release", "--allow-stale", "--force", "--dry-run", "--runner"]
    verb.placement == Dev::Placement::Host.new
    verb.listing.nil?
    verb.details == ["Accepts: cellbound-3d-win64-dev, cellbound-3d-linux64-dev, rspock", "Protocol: run: sh ./stage.sh"]
    verb.completions([]) == ["cellbound-3d-dev", "cellbound-3d-win64-dev", "cellbound-3d-linux64-dev", "rspock"]
    command(steam_channel, publishers: { "steam" => RecordingPublisher.new }).details ==
      ["Accepts: cellbound-3d-win64-release, cellbound-3d-linux64-release", "Protocol: publisher: steam"]
  end
end

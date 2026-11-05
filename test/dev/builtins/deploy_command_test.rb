# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/deploy_command"
require "dev/deploy_selector"
require "dev/dispatch"
require "dev/dispatch_resolver"
require "dev/host_environment"
require "dev/host_rule"
require "dev/lifecycle"
require "dev/lifecycle_executor"
require "dev/placement"
require "fileutils"
require "open3"
require "pathname"
require "stringio"
require "time"
require "tmpdir"

# The verb end to end through the LifecycleExecutor: a real git repo as
# the project (the staleness rule reads the tree), artifacts stamped into
# a real store in a temp data root, a real `run:` script recording what
# it was handed. The channel's protocol is placed on the host.
transform!(RSpock::AST::Transformation)
class Dev::Builtins::DeployCommandTest < Minitest::Test
  include SorbetHelper

  PLATFORM = Dev::Lifecycle::Platform
  CONFIG = Dev::Lifecycle::Config
  NOON = Time.utc(2026, 11, 4, 12, 0, 0)

  def setup
    @root = Pathname(Dir.mktmpdir("deploy-command-"))
    @project = @root / "project"
    @project.mkpath
    (@project / "stage.sh").write(<<~SH)
      #!/bin/sh
      set -eu
      echo "$DEV_CHANNEL $DEV_BUILD $DEV_BUILD_ID $DEV_SHA $DEV_DIRTY $DEV_ARTIFACT" >> "#{@root}/shipped"
    SH
    git("init", "-q")
    git("add", ".")
    commit("one")
    @out = StringIO.new
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

  def gem_target = Dev::Lifecycle::Target.new(name: "rspock", desc: "The gem")
  def targets = [client, gem_target]
  def store = Dev::Lifecycle::Store.new(project_name: "cellbound-3d", targets: targets, data_root: (@root / "data").to_s)
  def build(name) = Dev::Lifecycle::Build.parse(name, targets)

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

  def command(channel = self.channel("cellbound-3d-dev", "rspock"), placement: Dev::Placement::Host.new)
    host_rule = Dev::HostRule.new(host_environment: Dev::HostEnvironment.new(path: (@root / "no-marker").to_s), inside_container: false)
    ports = Dev::Lifecycle::Ports.new(project_root: @project)
    Dev::Builtins::DeployCommand.new(
      channel: channel,
      selector: Dev::DeploySelector.new(channel: channel, targets: targets, store: store),
      publisher: ports.publisher_for(channel),
      resolver: Dev::DispatchResolver.new(host_rule: host_rule),
      placement: placement,
      out: @out,
    )
  end

  def context
    Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui), project: Dev::ProjectContext.new(name: "cellbound-3d", root: @project))
  end

  def execute(verb, *words)
    Dev::LifecycleExecutor.new.execute(verb, args: parsed_args(verb, words), context: context)
  end

  test "bare `dev deploy staging` ships one artifact per accepted platform through the run: line, then reports each" do
    Given "a current artifact of every accepted build"
    win64 = stamp("cellbound-3d-win64-dev")
    linux64 = stamp("cellbound-3d-linux64-dev")
    gem = stamp("rspock")

    When
    execute(command)

    Then "the script ran once per archive with the channel, the build and the manifest's keys; the verb reported each"
    shipped == [
      "staging cellbound-3d-win64-dev 1.2.3+#{head} #{head} false #{win64.archive}",
      "staging cellbound-3d-linux64-dev 1.2.3+#{head} #{head} false #{linux64.archive}",
      "staging rspock 1.2.3+#{head} #{head} false #{gem.archive}",
    ]
    @out.string == <<~OUT
      deployed cellbound-3d-win64-dev (1.2.3+#{head}) → staging: #{win64.archive}
      deployed cellbound-3d-linux64-dev (1.2.3+#{head}) → staging: #{linux64.archive}
      deployed rspock (1.2.3+#{head}) → staging: #{gem.archive}
    OUT
  end

  test "--dry-run selects and reports, running no protocol" do
    Given
    stamp("cellbound-3d-win64-dev")
    stamp("cellbound-3d-linux64-dev")
    stamp("rspock")

    When
    execute(command, "rspock", "--dry-run")

    Then
    shipped == []
    @out.string == "would deploy rspock (1.2.3+#{head}) → staging: #{store.artifact(build("rspock")).archive}\n"
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

    When
    execute(command, "rspock", "--allow-stale")

    Then
    shipped == ["staging rspock 1.2.3+#{stale.manifest.state.sha} #{stale.manifest.state.sha} false #{stale.archive}"]
    @out.string == "deployed rspock (1.2.3+#{stale.manifest.state.sha}) → staging: #{stale.archive} — stale, shipped under --allow-stale\n"
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

  test "the verb's traits: the channel's desc, the selector's flags plus --dry-run, its placement, the accept set and protocol as details" do
    Given
    verb = command

    Expect
    verb.category == Dev::Command::Category::Lifecycle
    verb.desc == "rsync to the gamebox"
    verb.flags.map(&:name) == ["--config", "--allow-stale", "--force", "--dry-run"]
    verb.placement == Dev::Placement::Host.new
    verb.listing.nil?
    verb.details == ["Accepts: cellbound-3d-win64-dev, cellbound-3d-linux64-dev, rspock", "Protocol: run: sh ./stage.sh"]
    verb.completions([]) == ["cellbound-3d-dev", "cellbound-3d-win64-dev", "cellbound-3d-linux64-dev", "rspock"]
  end
end

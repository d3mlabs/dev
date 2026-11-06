# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/build_dispatcher"
require "dev/build_listing"
require "dev/build_selector"
require "dev/builtins/package_command"
require "dev/dispatch"
require "dev/dispatch_resolver"
require "dev/enrolled_runner_lookup"
require "dev/host_environment"
require "dev/host_rule"
require "dev/lifecycle"
require "dev/lifecycle_executor"
require "dev/placement"
require "dev/settings"
require "dev/target_placement"
require "digest"
require "fileutils"
require "open3"
require "pathname"
require "stringio"
require "support/scripted_remote"
require "time"
require "tmpdir"

# The verb end to end through the LifecycleExecutor: a real git repo as
# the project (the staleness rule reads the tree), a real build script
# counting its runs, a real store in a temp data root, dev's own zip
# packager. Every target is placed on the host of a linux64 machine; the
# remote cases force the dispatch with `--runner` over a scripted forge.
transform!(RSpock::AST::Transformation)
class Dev::Builtins::PackageCommandTest < Minitest::Test
  include SorbetHelper

  PLATFORM = Dev::Lifecycle::Platform
  CONFIG = Dev::Lifecycle::Config
  NOW = Time.utc(2026, 11, 4, 12, 30, 0)

  # The repo has no enrolled runner online.
  class NoneEnrolled < Dev::EnrolledRunnerLookup
    def available = nil
  end

  def setup
    @root = Pathname(Dir.mktmpdir("package-command-"))
    @project = @root / "project"
    @project.mkpath
    (@project / "build.sh").write(<<~SH)
      #!/bin/sh
      set -eu
      echo "$DEV_TARGET ${DEV_PLATFORM:-} ${DEV_CONFIG:-}" > "$DEV_INSTALL/built.txt"
      echo run >> "#{@root}/build-runs"
    SH
    (@project / "artifact.sh").write(<<~SH)
      #!/bin/sh
      set -eu
      mkdir -p "$DEV_INSTALL" && echo gem > "$DEV_INSTALL/rspock-3.0.0.gem"
    SH
    git("init", "-q")
    git("add", ".")
    commit("one")
    @out = StringIO.new
    @ui = typed_mock(Dev::Cli::Ui)
    @remote = ScriptedRemote.new(root: @project, ui: @ui, downloads: true)
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  def git(*args) = Open3.capture2e("git", "-C", @project.to_s, "-c", "user.name=t", "-c", "user.email=t@t", *args)
  def commit(message) = git("commit", "-q", "--allow-empty", "-m", message)
  def head = Open3.capture2("git", "-C", @project.to_s, "rev-parse", "--short=12", "HEAD").first.strip
  def build_runs = (@root / "build-runs").file? ? (@root / "build-runs").readlines.size : 0

  def client
    Dev::Lifecycle::Target.new(
      name: "cellbound-3d", desc: "Client", platforms: [PLATFORM::Linux64], configs: [CONFIG::Development, CONFIG::Release],
      builder: Dev::Lifecycle::BuilderSpec::Script.new(command: "sh ./build.sh"),
    )
  end

  def gem_target
    Dev::Lifecycle::Target.new(
      name: "rspock", desc: "The gem",
      builder: Dev::Lifecycle::BuilderSpec::Script.new(command: "sh ./artifact.sh"), packager: Dev::Lifecycle::PackagerSpec::AsIs.new,
    )
  end

  def adopted = Dev::Lifecycle::Target.new(name: "site", desc: "Prebuilt site", packager: Dev::Lifecycle::PackagerSpec::AsIs.new)

  def unshipped
    Dev::Lifecycle::Target.new(
      name: "tools", desc: "Dev tools", builder: Dev::Lifecycle::BuilderSpec::Script.new(command: "true"),
      packager: Dev::Lifecycle::PackagerSpec::None.new,
    )
  end

  def targets = [client, gem_target, adopted, unshipped]

  def store = Dev::Lifecycle::Store.new(project_name: "cellbound-3d", targets: targets, data_root: (@root / "data").to_s)

  def dispatcher
    host_rule = Dev::HostRule.new(host_environment: Dev::HostEnvironment.new(path: (@root / "no-marker").to_s), inside_container: false)
    placements = targets.to_h do |target|
      axis = target.platforms? ? target.platforms : [nil]
      host = axis.to_h { |platform| [platform, Dev::Placement::Host.new] }
      [target.name, Dev::TargetPlacement.new(target: target, placements: host, host_platform: PLATFORM::Linux64)]
    end
    settings = Dev::Settings.new(config_path: (@root / "config.yml").to_s, system_config_path: (@root / "none.yml").to_s)
    resolver = Dev::DispatchResolver.new(
      host_rule: host_rule, remotes: @remote.remotes, enrolled: NoneEnrolled.new, settings: settings, inside_job: false,
    )
    Dev::BuildDispatcher.new(placements: placements, resolver: resolver)
  end

  def command(semver: "1.2.3", now: NOW, step_outputs: Dev::Lifecycle::StepOutputs.new(path: nil))
    dispatcher = self.dispatcher
    Dev::Builtins::PackageCommand.new(
      selector: Dev::BuildSelector.new(targets: targets),
      dispatcher: dispatcher,
      listing: Dev::BuildListing.new(targets: targets, dispatcher: dispatcher),
      ports: Dev::Lifecycle::Ports.new(project_root: @project),
      store: store,
      semver: semver,
      clock: -> { now },
      step_outputs: step_outputs,
      out: @out,
    )
  end

  def context
    Dev::ExecutionContext.new(ui: @ui, project: Dev::ProjectContext.new(name: "cellbound-3d", root: @project))
  end

  def execute(verb, *words)
    Dev::LifecycleExecutor.new.execute(verb, args: parsed_args(verb, words), context: context)
  end

  def build(name) = Dev::Lifecycle::Build.parse(name, targets)

  test "bare `dev package` builds the first target's default build, zips the install and stamps build-id.json last" do
    Given
    the_build = build("cellbound-3d-linux64-dev")

    When
    execute(command)

    Then "the builder ran once into the store's install dir; the archive sits beside the manifest, " \
         "which records the clean tree, the builder and the archive's digest; the verb reports the artifact"
    build_runs == 1
    (store.install_dir(the_build) / "built.txt").read == "cellbound-3d linux64 dev\n"
    artifact = store.artifact(the_build)
    artifact.archive == store.dir(the_build) / "cellbound-3d-linux64-dev.zip"
    artifact.archive.file?
    artifact.manifest.state == Dev::Lifecycle::GitState.new(sha: head, dirty: false)
    artifact.manifest.builder == "script"
    artifact.manifest.builder_version.nil?
    artifact.manifest.build_id == Dev::Lifecycle::BuildId.new("1.2.3+#{head}")
    artifact.manifest.packaged_at == NOW
    artifact.manifest.archive == "cellbound-3d-linux64-dev.zip"
    artifact.manifest.archive_sha256 == Digest::SHA256.file(artifact.archive.to_s).hexdigest
    artifact.current?(Dev::Lifecycle::GitState.read(@project))
    @out.string == "packaged cellbound-3d-linux64-dev → #{artifact.archive} (1.2.3+#{head})\n"
  end

  test "a current artifact skips the build and re-packages the install" do
    Given "an artifact packaged from this clean tree"
    execute(command)
    @out.truncate(0)
    @out.rewind

    When "packaged again with nothing changed"
    execute(command)

    Then
    build_runs == 1
    @out.string.lines.first == "build skipped: the artifact is current (1.2.3+#{head})\n"
  end

  test "a new commit makes the artifact stale: the build runs again and the stamp follows the commit" do
    Given "an artifact packaged from the previous commit"
    execute(command)
    commit("two")
    @out.truncate(0)
    @out.rewind

    When
    execute(command)

    Then
    build_runs == 2
    !@out.string.include?("build skipped")
    store.artifact(build("cellbound-3d-linux64-dev")).manifest.state.sha == head
  end

  test "a dirty tree is never current: the build runs each time and the id carries dirty and the instant" do
    Given
    (@project / "wip.txt").write("x")
    execute(command)
    @out.truncate(0)
    @out.rewind

    When
    execute(command)

    Then
    build_runs == 2
    store.artifact(build("cellbound-3d-linux64-dev")).manifest.build_id == Dev::Lifecycle::BuildId.new("1.2.3+#{head}.dirty.20261104T123000Z")
  end

  test "--no-build packages the install as it is" do
    Given "an install the builder left"
    execute(command, "cellbound-3d-release")
    commit("two")
    @out.truncate(0)
    @out.rewind

    When
    execute(command, "cellbound-3d-release", "--no-build")

    Then
    build_runs == 1
    @out.string.lines.first == "build skipped: --no-build given\n"
    store.artifact(build("cellbound-3d-linux64-release")).manifest.state.sha == head
  end

  test "a target with no build: packages alone — as-is adopts the one file in its install" do
    Given
    install = store.install_dir(build("site"))
    install.mkpath
    (install / "site.tar.gz").write("site")

    When
    execute(command, "site")

    Then
    build_runs == 0
    @out.string.lines.first == "build skipped: target 'site' declares no `build:`\n"
    artifact = store.artifact(build("site"))
    artifact.archive == store.dir(build("site")) / "site.tar.gz"
    artifact.manifest.builder == "none"
  end

  test "a script builder writing the gem, adopted as-is, lands as <build>.gem" do
    When
    execute(command, "rspock")

    Then
    store.artifact(build("rspock")).archive == store.dir(build("rspock")) / "rspock.gem"
  end

  test "a target declaring packager: none is refused by name before anything runs" do
    When
    execute(command, "tools")

    Then
    e = raises Dev::Builtins::PackageCommand::NotPackageableError
    e.message == "target 'tools' declares `packager: none` — it is built, never packaged; `dev build tools` builds it"
    @out.string == ""
  end

  test "a failing builder leaves no manifest behind: the directory reads as unpackaged" do
    Given
    (@project / "build.sh").write("exit 3\n")

    When
    execute(command)

    Then
    raises Dev::Lifecycle::ScriptBuilder::BuildScriptFailedError
    store.artifact(build("cellbound-3d-linux64-dev")).nil?
    @out.string == ""
  end

  test "`after` without a packed archive is a wiring bug, named" do
    Given
    env = Dev::Builtins::PackageCommand::PackageEnv.new(
      build: build("site"), install: Pathname("/i"), archive_stem: Pathname("/a"), builder: nil,
      packager: Dev::Lifecycle::AsIsPackager.new, state: Dev::Lifecycle::GitState.new(sha: nil, dirty: true), build_skipped: nil,
    )

    When
    env.packed!

    Then
    raises Dev::Builtins::PackageCommand::NothingPackedError
  end

  test "inside an Actions job, a package names its artifact and files as step outputs for the workflow's upload" do
    Given "a GITHUB_OUTPUT file"
    outputs = @root / "github-output"
    outputs.write("existing=1\n")

    When
    execute(command(step_outputs: Dev::Lifecycle::StepOutputs.new(path: outputs)), "cellbound-3d-release")

    Then "the artifact's name, then its files — the archive and the manifest — fenced as GitHub reads a multi-line value"
    artifact = store.artifact(build("cellbound-3d-linux64-release"))
    lines = outputs.read.lines(chomp: true)
    lines.fetch(0) == "existing=1"
    lines.fetch(1) == "artifact=cellbound-3d-linux64-release"
    lines.fetch(2).match?(/\Aartifact_files<<dev-\h{16}\z/)
    lines.fetch(3) == artifact.archive.to_s
    lines.fetch(4) == (artifact.dir / "build-id.json").to_s
    lines.fetch(5) == lines.fetch(2).delete_prefix("artifact_files<<")
    lines.size == 6
  end

  test "outside a job nothing is written anywhere: the step outputs are inert" do
    Expect
    !Dev::Lifecycle::StepOutputs.from_env({}).active?
    !Dev::Lifecycle::StepOutputs.from_env({ "GITHUB_OUTPUT" => "" }).active?
    Dev::Lifecycle::StepOutputs.from_env({ "GITHUB_OUTPUT" => "/tmp/x" }).active?
  end

  test "`--runner` sends `package <build>#{suffix}` to the label; nothing is built, packaged or reported here" do
    Given
    @remote.install_workflow
    @ui.expects(:print_remote_crossing).with(runner: "linux-pool", snapshot: ScriptedRemote::SHA[0, 12])

    When
    execute(command, "cellbound-3d-release", *extra, "--runner", "linux-pool")

    Then
    @remote.dispatched_verbs == "package cellbound-3d-linux64-release#{suffix}"
    @remote.dispatched_inputs.fetch("fetch") == "false"
    @remote.download.nil?
    build_runs == 0
    store.artifact(build("cellbound-3d-linux64-release")).nil?
    @out.string == ""

    Where
    extra          | suffix
    []             | ""
    ["--no-build"] | " --no-build"
  end

  test "`--fetch` asks the workflow to upload, then downloads the artifact by the build's name into the build's store directory" do
    Given
    @remote.install_workflow
    @ui.stubs(:print_remote_crossing)
    the_build = build("cellbound-3d-linux64-release")

    When
    execute(command, "cellbound-3d-release", "--runner", "linux-pool", "--fetch")

    Then
    @remote.dispatched_inputs == { "verbs" => "package cellbound-3d-linux64-release", "runner" => "linux-pool", "fetch" => "true" }
    @remote.download == ["run", "download", "42", "--name", "cellbound-3d-linux64-release", "--dir", store.dir(the_build).to_s]
    store.dir(the_build).directory?
    @remote.out.string.lines.last == "fetched cellbound-3d-linux64-release → #{store.dir(the_build)}\n"
  end

  test "a target declaring packager: none is refused before any dispatch, remote included" do
    When
    execute(command, "tools", "--runner", "linux-pool")

    Then
    raises Dev::Builtins::PackageCommand::NotPackageableError
    @remote.dispatched_verbs.nil?
  end

  test "the verb's traits: the selector's flags plus --no-build, --runner and --fetch; only packageable targets are listed and completed" do
    Given
    verb = command

    Expect
    verb.category == Dev::Command::Category::Lifecycle
    verb.flags.map(&:name) == ["--target", "--platform", "--config", "--no-build", "--runner", "--fetch"]
    verb.desc.lines.first.start_with?("Package a build into its artifact")
    verb.listing.heading == "Builds"
    verb.listing.subjects.map(&:name) == ["cellbound-3d-linux64-dev", "cellbound-3d-linux64-release", "rspock", "site"]
    verb.completions([]) == ["cellbound-3d", "cellbound-3d-dev", "cellbound-3d-release", "cellbound-3d-linux64",
                             "cellbound-3d-linux64-dev", "cellbound-3d-linux64-release", "rspock", "site"]
  end
end

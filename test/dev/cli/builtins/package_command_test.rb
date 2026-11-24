# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/build_dispatcher"
require "dev/cli/build_listing"
require "dev/cli/build_selector"
require "dev/cli/builtins/package_command"
require "dev/cli/dispatch"
require "dev/cli/dispatch_resolver"
require "dev/deps/gh_publisher"
require "dev/enrolled_runner_lookup"
require "dev/host_environment"
require "dev/cli/host_rule"
require "dev/lifecycle"
require "dev/cli/lifecycle_executor"
require "dev/cli/placement"
require "dev/settings"
require "dev/cli/target_placement"
require "digest"
require "fileutils"
require "open3"
require "pathname"
require "stringio"
require "support/recording_publisher"
require "support/scripted_remote"
require "support/tool_tree_fixtures"
require "time"
require "tmpdir"

# The verb end to end through the LifecycleExecutor: a real git repo as
# the project (the staleness rule reads the tree), a real build script
# counting its runs, a real store in a temp data root, dev's own zip
# packager. Every target is placed on the host of a linux64 machine; the
# remote cases force the dispatch with `--runner` over a scripted forge.
# The checkout also carries a self-contained tool tree, which the
# channels accepting its target are shown before it is archived.
transform!(RSpock::AST::Transformation)
class Dev::Cli::Builtins::PackageCommandTest < Minitest::Test
  include SorbetHelper
  include ToolTreeFixtures

  PLATFORM = Dev::Lifecycle::Platform
  CONFIG = Dev::Lifecycle::Config
  NOW = Time.utc(2026, 11, 4, 12, 30, 0)
  # The project's tracked files: the two scripts, VERSION and the tool tree.
  TRACKED = %w[Gemfile VERSION artifact.sh build.sh dependencies.rb deps.lock exe].freeze
  TRACKED_ENTRIES = %w[Gemfile VERSION artifact.sh build.sh dependencies.rb deps.lock exe/ exe/ai-flow].freeze

  # The repo has no enrolled runner online.
  class NoneEnrolled < Dev::EnrolledRunnerLookup
    def available
      nil
    end
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
    (@project / "VERSION").write("1.2.3\n")
    tool_tree(@project)
    git("init", "-q")
    git("add", ".")
    commit("one")
    @tool = tool_target
    @out = StringIO.new
    @ui = typed_mock(Dev::Ui)
    @remote = ScriptedRemote.new(root: @project, ui: @ui, downloads: true)
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  def git(*args)
    Open3.capture2e("git", "-C", @project.to_s, "-c", "user.name=t", "-c", "user.email=t@t", *args)
  end

  def commit(message)
    git("commit", "-q", "--allow-empty", "-m", message)
  end

  def head
    Open3.capture2("git", "-C", @project.to_s, "rev-parse", "--short=12", "HEAD").first.strip
  end

  def build_runs
    (@root / "build-runs").file? ? (@root / "build-runs").readlines.size : 0
  end

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

  def checkout_target
    Dev::Lifecycle::Target.new(name: "site", desc: "The tracked files, zipped")
  end

  def unshipped
    Dev::Lifecycle::Target.new(
      name: "tools", desc: "Dev tools", builder: Dev::Lifecycle::BuilderSpec::Script.new(command: "true"),
      packager: Dev::Lifecycle::PackagerSpec::None.new,
    )
  end

  # A self-contained tool as ai-flow ships it: the checkout is the stage,
  # `files:` selects what ships.
  def tool_target(files: ["/exe", "/dependencies.rb", "/deps.lock", "/Gemfile"])
    Dev::Lifecycle::Target.new(
      name: "ai-flow", desc: "The dispatcher",
      packager: Dev::Lifecycle::PackagerSpec::Archive.new(files: Dev::Lifecycle::FileSelection.parse(files)),
    )
  end

  # The tool target as a test declares it; `tool_target` unless a test
  # reshapes its `files:` before building the command.
  def targets
    [client, gem_target, checkout_target, unshipped, @tool]
  end

  def store
    Dev::Lifecycle::Store.new(project_name: "cellbound-3d", targets: targets, data_root: (@root / "data").to_s)
  end

  def dispatcher
    host_rule = Dev::Cli::HostRule.new(host_environment: Dev::HostEnvironment.new(path: (@root / "no-marker").to_s), inside_container: false)
    placements = targets.to_h do |target|
      axis = target.platforms? ? target.platforms : [nil]
      host = axis.to_h { |platform| [platform, Dev::Cli::Placement::Host.new] }
      [target.name, Dev::Cli::TargetPlacement.new(target: target, placements: host, host_platform: PLATFORM::Linux64)]
    end
    settings = Dev::Settings.new(config_path: (@root / "config.yml").to_s, system_config_path: (@root / "none.yml").to_s)
    resolver = Dev::Cli::DispatchResolver.new(
      host_rule: host_rule, remotes: @remote.remotes, enrolled: NoneEnrolled.new, settings: settings,
    )
    Dev::Cli::BuildDispatcher.new(placements: placements, resolver: resolver)
  end

  # @param channels [Hash{Dev::Lifecycle::Channel => Dev::Lifecycle::Publisher}]
  #   the project's channels with the publisher each names
  def command(now: NOW, step_outputs: Dev::Lifecycle::StepOutputs.new(path: nil), channels: {})
    dispatcher = self.dispatcher
    publishers = channels.to_h { |channel, publisher| [channel.publisher.name, publisher] }
    Dev::Cli::Builtins::PackageCommand.new(
      selector: Dev::Cli::BuildSelector.new(targets: targets),
      dispatcher: dispatcher,
      listing: Dev::Cli::BuildListing.new(targets: targets, dispatcher: dispatcher),
      ports: Dev::Lifecycle::Ports.new(project_root: @project, publishers:),
      store: store,
      channels: channels.keys,
      clock: -> { now },
      step_outputs: step_outputs,
      out: @out,
    )
  end

  # An integration channel accepting the named targets.
  def channel(name, *accepted)
    Dev::Lifecycle::Channel.new(
      name:, accepts: accepted.map { |target_name| Dev::Lifecycle::BuildPattern.parse(target_name, targets) },
      publisher: Dev::Lifecycle::PublisherSpec::Integration.new(name:),
    )
  end

  def gh_publisher
    Dev::Deps::GhPublisher.new(project_root: @project)
  end

  def archive_entries(name)
    Open3.capture2("unzip", "-Z1", store.artifact(build(name)).archive.to_s).first.lines.map(&:chomp).sort
  end

  def context
    Dev::Cli::ExecutionContext.new(ui: @ui, project: Dev::Cli::ProjectContext.new(name: "cellbound-3d", root: @project))
  end

  def execute(verb, *words)
    Dev::Cli::LifecycleExecutor.new.execute(verb, args: parsed_args(verb, words), context: context)
  end

  def build(name)
    Dev::Lifecycle::Build.parse(name, targets)
  end

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

  test "the build id's semver is read from VERSION as it is at package time, so a release's bump commit is what it stamps" do
    Given "an artifact packaged at 1.2.3, then the version bumped and committed"
    execute(command)
    (@project / "VERSION").write("1.3.0\n")
    git("add", "VERSION")
    commit("Bump version to 1.3.0")

    When
    execute(command)

    Then
    store.artifact(build("cellbound-3d-linux64-dev")).manifest.build_id == Dev::Lifecycle::BuildId.new("1.3.0+#{head}")
  end

  test "a project without a VERSION file stamps the default semver" do
    Given
    git("rm", "-q", "VERSION")
    commit("no version in source")

    When
    execute(command)

    Then
    store.artifact(build("cellbound-3d-linux64-dev")).manifest.build_id ==
      Dev::Lifecycle::BuildId.new("#{Dev::Lifecycle::BuildId::DEFAULT_SEMVER}+#{head}")
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

  test "a target with no build: stages the checkout's tracked files and archives them; untracked files never ship (dev#674)" do
    Given "an untracked file beside the tracked ones, and a stale file in the stage"
    (@project / "notes.txt").write("untracked")
    install = store.install_dir(build("site"))
    install.mkpath
    (install / "stale.txt").write("from a previous build")

    When
    execute(command, "site")

    Then "the checkout builder ran (no script did); the zip holds exactly the tracked files; the manifest names the builder"
    build_runs == 0
    !@out.string.include?("build skipped")
    install.children.map { |child| child.basename.to_s }.sort == TRACKED
    artifact = store.artifact(build("site"))
    artifact.archive == store.dir(build("site")) / "site.zip"
    Open3.capture2("unzip", "-Z1", artifact.archive.to_s).first.lines.map(&:chomp).sort == TRACKED_ENTRIES
    artifact.manifest.builder == "checkout"
    artifact.manifest.builder_version.nil?
  end

  test "a target with no build: is current like any other: a second package from the same clean tree skips the checkout copy" do
    Given
    execute(command, "site")
    (store.install_dir(build("site")) / "marker.txt").write("left by hand")
    @out.truncate(0)
    @out.rewind

    When
    execute(command, "site")

    Then "the stage was not refreshed, so the marker survived into the re-archived zip"
    @out.string.lines.first == "build skipped: the artifact is current (1.2.3+#{head})\n"
    (store.install_dir(build("site")) / "marker.txt").file?
  end

  test "a complete self-contained tree packages for the gh channel: the selection ships, nothing of the checkout beyond it" do
    Given "the gh channel accepting ai-flow, and another publisher beside it"
    recording = RecordingPublisher.new
    verb = command(channels: { channel("gh", "ai-flow") => gh_publisher, channel("brew", "ai-flow", "site") => recording })

    When
    execute(verb, "ai-flow")

    Then
    archive_entries("ai-flow") == %w[Gemfile dependencies.rb deps.lock exe/ exe/ai-flow]
    @out.string.start_with?("packaged ai-flow → ")
    recording.calls.empty?
  end

  test "a self-contained tree whose files: leaves deps.lock out is refused at package, naming the channel and the lock; no artifact lands (dev#676)" do
    Given "ai-flow's files: without its lock, and the gh channel accepting it"
    @tool = tool_target(files: ["/exe", "/dependencies.rb", "/Gemfile"])
    verb = command(channels: { channel("gh", "ai-flow") => gh_publisher })

    When
    execute(verb, "ai-flow")

    Then
    error = raises Dev::Deps::GhPublisher::IncompleteTreeError
    error.message == "channel 'gh' refuses the tree as it would ship: " \
      "it ships dependencies.rb without deps.lock — a self-contained tree carries its lock beside its manifest"
    store.artifact(build("ai-flow")).nil?
    @out.string == ""
  end

  test "a Gemfile whose deps.lock pins no Ruby is refused at package" do
    Given
    (@project / "deps.lock").write(ToolTreeFixtures::FORMULA_LOCK)
    git("add", "deps.lock")
    commit("drop the ruby pin")
    verb = command(channels: { channel("gh", "ai-flow") => gh_publisher })

    When
    execute(verb, "ai-flow")

    Then
    error = raises Dev::Deps::GhPublisher::IncompleteTreeError
    error.message.include?("channel 'gh' refuses")
    error.message.include?("pins no ruby in deps.lock")
    store.artifact(build("ai-flow")).nil?
  end

  test "a bin/<name> in the selection colliding with exe/<name> is refused at package" do
    Given "a bin/ai-flow of the tree's own, selected"
    (@project / "bin").mkpath
    (@project / "bin/ai-flow").write("#!/bin/sh\necho mine\n")
    git("add", "bin")
    commit("a bin of its own")
    @tool = tool_target(files: ["/exe", "/bin", "/dependencies.rb", "/deps.lock", "/Gemfile"])
    verb = command(channels: { channel("gh", "ai-flow") => gh_publisher })

    When
    execute(verb, "ai-flow")

    Then
    error = raises Dev::Deps::GhPublisher::IncompleteTreeError
    error.message.include?("carries bin/ai-flow beside exe/ai-flow")
    store.artifact(build("ai-flow")).nil?
  end

  test "a channel whose targets: does not name the build is not asked: the incomplete tree packages for the channels that take it" do
    Given "the gh channel accepting the client only, a recording channel accepting ai-flow"
    @tool = tool_target(files: ["/exe", "/dependencies.rb", "/Gemfile"])
    recording = RecordingPublisher.new
    verb = command(channels: { channel("gh", "cellbound-3d") => gh_publisher, channel("brew", "ai-flow") => recording })

    When
    execute(verb, "ai-flow")

    Then "the default acceptance of every other publisher: the archive lands"
    archive_entries("ai-flow") == %w[Gemfile dependencies.rb exe/ exe/ai-flow]
  end

  test "a build that is no self-contained tree is accepted by the gh channel as the plain asset it is" do
    Given "the client's install: one built file, no manifest"
    verb = command(channels: { channel("gh", "cellbound-3d") => gh_publisher })

    When
    execute(verb, "cellbound-3d-release")

    Then
    archive_entries("cellbound-3d-linux64-release") == ["built.txt"]
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
    e = raises Dev::Cli::Builtins::PackageCommand::NotPackageableError
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
    env = Dev::Cli::Builtins::PackageCommand::PackageEnv.new(
      build: build("site"), install: Pathname("/i"), archive_stem: Pathname("/a"),
      builder: Dev::Lifecycle::CheckoutBuilder.new(project_root: @project), packager: Dev::Lifecycle::Archive.new,
      acceptance: Dev::Lifecycle::Acceptance.unconditional,
      state: Dev::Lifecycle::GitState.new(sha: nil, dirty: true), build_skipped: nil,
    )

    When
    env.packed!

    Then
    raises Dev::Cli::Builtins::PackageCommand::NothingPackedError
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
    @ui.expects(:print_remote_crossing).with(destination: "on linux-pool", workspace: ScriptedRemote::WORKSPACE)

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
    raises Dev::Cli::Builtins::PackageCommand::NotPackageableError
    @remote.dispatched_verbs.nil?
  end

  test "the verb's traits: the selector's flags plus --no-build, --runner, --container and --fetch; only packageable targets are listed and completed" do
    Given
    verb = command

    Expect
    verb.category == Dev::Cli::Command::Category::Lifecycle
    verb.flags.map(&:name) == ["--target", "--platform", "--config", "--no-build", "--runner", "--container", "--fetch"]
    verb.desc.lines.first.start_with?("Package a build into its artifact")
    verb.listing.heading == "Builds"
    verb.listing.subjects.map(&:name) == ["cellbound-3d-linux64-dev", "cellbound-3d-linux64-release", "rspock", "site", "ai-flow"]
    verb.completions([]) == ["cellbound-3d", "cellbound-3d-dev", "cellbound-3d-release", "cellbound-3d-linux64",
                             "cellbound-3d-linux64-dev", "cellbound-3d-linux64-release", "rspock", "site", "ai-flow"]
  end
end

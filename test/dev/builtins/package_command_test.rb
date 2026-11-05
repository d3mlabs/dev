# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/build_dispatcher"
require "dev/build_listing"
require "dev/build_selector"
require "dev/builtins/package_command"
require "dev/dispatch"
require "dev/dispatch_resolver"
require "dev/host_environment"
require "dev/host_rule"
require "dev/lifecycle"
require "dev/lifecycle_executor"
require "dev/placement"
require "dev/target_placement"
require "digest"
require "fileutils"
require "open3"
require "pathname"
require "stringio"
require "time"
require "tmpdir"

# The verb end to end through the LifecycleExecutor: a real git repo as
# the project (the staleness rule reads the tree), a real build script
# counting its runs, a real store in a temp data root, dev's own zip
# packager. Every target is placed on the host of a linux64 machine.
transform!(RSpock::AST::Transformation)
class Dev::Builtins::PackageCommandTest < Minitest::Test
  include SorbetHelper

  PLATFORM = Dev::Lifecycle::Platform
  CONFIG = Dev::Lifecycle::Config
  NOW = Time.utc(2026, 11, 4, 12, 30, 0)

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
    Dev::BuildDispatcher.new(placements: placements, resolver: Dev::DispatchResolver.new(host_rule: host_rule))
  end

  def command(semver: "1.2.3", now: NOW)
    dispatcher = self.dispatcher
    Dev::Builtins::PackageCommand.new(
      selector: Dev::BuildSelector.new(targets: targets),
      dispatcher: dispatcher,
      listing: Dev::BuildListing.new(targets: targets, dispatcher: dispatcher),
      ports: Dev::Lifecycle::Ports.new(project_root: @project),
      store: store,
      semver: semver,
      clock: -> { now },
      out: @out,
    )
  end

  def context
    Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui), project: Dev::ProjectContext.new(name: "cellbound-3d", root: @project))
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

  test "the verb's traits: the selector's flags plus --no-build; only packageable targets are listed and completed" do
    Given
    verb = command

    Expect
    verb.category == Dev::Command::Category::Lifecycle
    verb.flags.map(&:name) == ["--target", "--platform", "--config", "--no-build"]
    verb.desc.lines.first.start_with?("Package a build into its artifact")
    verb.listing.heading == "Builds"
    verb.listing.subjects.map(&:name) == ["cellbound-3d-linux64-dev", "cellbound-3d-linux64-release", "rspock", "site"]
    verb.completions([]) == ["cellbound-3d", "cellbound-3d-dev", "cellbound-3d-release", "cellbound-3d-linux64",
                             "cellbound-3d-linux64-dev", "cellbound-3d-linux64-release", "rspock", "site"]
  end
end

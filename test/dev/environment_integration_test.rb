# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev"
require "dev/build_container"
require "dev/container_engine"
require "dev/container_github_token"
require "dev/deps"
require "dev/deps/dependency"
require "dev/deps/lockfile"
require "dev/environment_image"
require "dev/host_environment"
require "dev/host_rule"
require "dev/platform"
require "dev/project_container"
require "dev/runner"
require "dev/shadowenv_llvm"
require "support/fake_container_engine"
require "support/scripted_remote"
require "fileutils"
require "pathname"
require "stringio"
require "tmpdir"
require "yaml"

# dev#307's and dev#409's done-whens, through the composition root: a
# checkout whose lock pins two images and whose dev.yml places each command
# by name with `environment:`, bound against the lock at load. The process
# boundaries are faked — the engine (the image is "found locally", so no
# registry is reached), the exec — and everything between dev.yml and the
# argv dev would exec is real.
transform!(RSpock::AST::Transformation)
class EnvironmentIntegrationTest < Minitest::Test
  include SorbetHelper

  COMMANDS = {
    "build" => { "run" => "./bin/build.sh", "environment" => "snappy-linux", "desc" => "Build the game" },
    "test-server" => { "run" => "./bin/test-server.sh", "environment" => "snappy-server", "desc" => "Test the server" },
    "editor" => { "run" => "./bin/editor.sh", "environment" => "host", "desc" => "Open the editor" },
  }.freeze

  def setup
    @original_cwd = Dir.pwd
    @root = Pathname(Dir.mktmpdir("environment-fixture"))
    Dev.stubs(:target_project_root).returns(@root)
    # A workstation: the fixture is never `dev up`'d, and in CI the
    # staleness guard turns that into an exit(1) — a real one, which the
    # tests below that do not expect an exit would take the whole suite
    # down with (Minitest passes SystemExit through).
    Dev::Deps.stubs(:detect_env).returns("dev")
    # A Mac: neither image's platform, so both commands reach their container.
    Dev::Platform.stubs(:current).returns("darwin-arm64")
    # Every docker call succeeds (the image is found locally) except the
    # persistent container's existence probe, so a persisted image creates
    # its container and the test can see the shape it was created with.
    @engine = FakeContainerEngine.new(&method(:docker_succeeds?))
    Dev::ContainerEngine.stubs(:resolve).returns(@engine)
    Dev::ShadowenvLlvm.stubs(:project_needs_llvm?).returns(false)
    @stderr = StringIO.new
    @original_stderr = $stderr
    $stderr = @stderr
  end

  def teardown
    $stderr = @original_stderr
    Dir.chdir(@original_cwd)
    FileUtils.rm_rf(@root)
    super
  end

  test "a fixture with two image blocks runs dev build in one and dev test-server in the other" do
    Given "two pinned images, the server's persisted with a volume"
    linux, server = lock(
      image_pin("snappy-linux"),
      image_pin("snappy-server", "persist" => true, "volumes" => ["/e:/ue"]),
    )
    runner = runner(COMMANDS)
    execs = record_execs
    Kernel.stubs(:exit)

    When "each command is run"
    exec!(runner, ["build"])
    exec!(runner, ["test-server"])
    created = @engine.runs.find(&method(:service_create?))
    mounts = created.each_cons(2).select { |flag, _| flag == "-v" }.map(&:last)

    Then "build is a one-shot run of the linux image; test-server an exec into the server image's persistent container, created with its volume — both through the engine, each the workspace program ending in the command, nothing exec'd"
    execs.empty?
    run = @engine.runs.find { |verb, *_rest| verb == "run" }
    run.first(2) == ["run", "--rm"]
    run[-4, 3] == [linux.ref, "sh", "-c"]
    run.last.end_with?("exec sh -c ./bin/build.sh\n")
    exec = @engine.runs.find { |verb, *_rest| verb == "exec" }
    exec[0, 4] == ["exec", Dev::BuildContainer.service_container_name(server.ref, @root), "sh", "-c"]
    exec.last.end_with?("exec sh -c ./bin/test-server.sh\n")
    created.include?(server.ref)
    mounts.include?("/e:/ue")
    mounts.none? { |spec| spec.start_with?(@root.to_s) }
  end

  test "environment: host runs the command here, whatever the lock pins" do
    Given
    lock(image_pin("snappy-linux"), image_pin("snappy-server"))
    runner = runner(COMMANDS)

    When
    exec!(runner, ["editor"])

    Then "shadowenv exec on this host, no docker"
    1 * Kernel.exec(has_entries("RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", includes("./bin/editor.sh"))
  end

  test "a container-placed run prints the crossing line once; a host run prints nothing extra" do
    Given
    lock(image_pin("snappy-linux"), image_pin("snappy-server"))
    ui = fake_ui
    runner = runner(COMMANDS, ui:)
    record_execs
    Kernel.stubs(:exit)

    When
    exec!(runner, ["build"])
    exec!(runner, ["editor"])

    Then
    1 * ui.print_remote_crossing(destination: "in snappy-linux (container)", snapshot: ScriptedRemote::SHA[0, 12])
    0 * ui.print_remote_crossing(destination: includes("host"), snapshot: anything)
  end

  test "dev help shows each project command's environment on this machine; builtins are not annotated" do
    Given "a Mac: neither image is native here"
    lock(image_pin("snappy-linux"), image_pin("snappy-server"))
    out = StringIO.new
    runner = runner(COMMANDS, out:)

    When
    runner.run(["help"])
    lines = out.string.lines.map(&:chomp)

    Then "a trailing column per project command, in a container where the host rule enters one"
    lines.include?("  build        Build the game   snappy-linux (container)")
    lines.include?("  test-server  Test the server  snappy-server (container)")
    lines.include?("  editor       Open the editor  host")
    lines.grep(/^  deps /).first == "  deps …       Manage dependencies (update | install | check | path)"
  end

  test "dev help <cmd> says the environment in a sentence" do
    Given
    lock(image_pin("snappy-linux"), image_pin("snappy-server"))
    out = StringIO.new
    runner = runner(COMMANDS, out:)

    When
    runner.run(["help", "build"])

    Then
    out.string == "Usage: dev build [args...]\n\nBuild the game\nRuns in snappy-linux, in a container on this machine.\n"
  end

  test "a command naming none among several pins fails at load — at dev help, with both names listed" do
    Given
    lock(image_pin("snappy-linux"), image_pin("snappy-server"))
    runner = runner(COMMANDS.merge("lint" => { "run" => "./bin/lint.sh" }))
    Kernel.expects(:exec).never
    Kernel.expects(:exit).with(1).once

    When
    runner.run(["help"])

    Then "the refusal names the command, both images, and the key to add"
    @stderr.string.include?("dev: `lint` runs in a container but names no image")
    @stderr.string.include?("snappy-linux, snappy-server")
    @stderr.string.include?("environment: <name>")
  end

  test "a command naming an image the lock does not pin fails at load with the pin list, whatever command is asked for" do
    Given
    lock(image_pin("snappy-linux"), image_pin("snappy-server"))
    runner = runner(COMMANDS.merge("deploy" => { "run" => "./bin/deploy.sh", "environment" => "snappy-srv" }))
    Kernel.expects(:exec).never
    Kernel.expects(:exit).with(1).twice

    When
    runner.run(["help"])
    runner.run(["build"])

    Then
    @stderr.string.include?("dev: `deploy` runs in `snappy-srv`, which the lock does not pin")
    @stderr.string.include?("snappy-linux, snappy-server")
  end

  test "a target's build pointed at an image that does not produce its platform is reported at load with the fix named; help lists it unbound and the build refuses until the re-lock (dev#192 K8, dev#450)" do
    Given "the Linux image declares linux64 only; the client asks it for win64"
    lock(image_pin("snappy-linux", "target_platforms" => ["linux64"]), image_pin("snappy-server"))
    out = StringIO.new
    runner = runner(
      COMMANDS.slice("editor"),
      out:,
      targets: { "snappy" => { "platforms" => ["win64", "linux64"], "environment" => "snappy-linux" } },
    )
    Kernel.expects(:exec).never
    Kernel.expects(:exit).with(1).once

    When
    runner.run(["help", "build"])
    runner.run(["build", "snappy-linux64"])

    Then "the mismatch is on stderr once per load, the builds list without a column, and the build asked to run is refused as unbound"
    @stderr.string.scan("dev: `snappy-win64` builds in snappy-linux, which does not produce win64").size == 2
    @stderr.string.include?("add `target_platforms :win64` to its image block in dependencies.rb")
    out.string.include?("snappy-win64")
    out.string.include?("snappy-linux64")
    !out.string.include?("snappy-linux ")
    @stderr.string.include?("`snappy-linux64` has no environment bound")
  end

  test "target_platforms declared in the image block reach the lock and satisfy the check, so the project loads and runs" do
    Given "the image block as cellbound-3d writes it, locked through the real DSL materialization"
    declaration = Dev::Deps.define do
      image "snappy-linux", from: "ghcr.io/d3mlabs/unreal-engine-build-base:ue5.8-3" do
        platform "linux/amd64"
        target_platforms :win64, :linux64
      end
    end.declarations[0]
    lock(image_pin("snappy-linux", declaration.materialization))
    runner = runner(
      COMMANDS.slice("editor"),
      targets: {
        "snappy" => { "platforms" => ["win64", "linux64"], "environment" => "snappy-linux" },
        "snappy-editor" => { "platforms" => ["linux64", "macos"], "environment" => { "linux64" => "snappy-linux", "macos" => "host" } },
      },
    )
    execs = record_execs

    When
    exec!(runner, ["editor"])

    Then "no refusal: the lock carries the capability and the command ran"
    !@stderr.string.include?("does not produce")
    !@stderr.string.include?("the lock does not pin")
    execs.size == 1
    Dev::Deps::Lockfile.new(dir: @root).read.find { |pin| pin.name == "snappy-linux" }.metadata["target_platforms"] == ["win64", "linux64"]
  end

  test "a lock another dev locked keeps its remediation reachable: the message once on stderr, help without the column, a project command refused" do
    Given "a pin whose stored digest is not this dev's"
    lock(image_pin("snappy-linux"))
    lockfile = Dev::Deps::Lockfile.new(dir: @root)
    lockfile.lock(lockfile.read.map { |pin| pin.with(metadata: pin.metadata.merge(Dev::EnvironmentImage::DIGEST_KEY => "f" * 64)) })
    out = StringIO.new
    runner = runner(COMMANDS, out:)
    Kernel.expects(:exec).never
    Kernel.expects(:exit).with(1).once

    When
    runner.run(["help"])
    runner.run(["build"])

    Then
    @stderr.string.scan("run: dev deps update").size >= 1
    out.string.include?("  build        Build the game\n")
    @stderr.string.include?("`./bin/build.sh` has no environment bound")
  end

  test "runs_on: is refused at load with its one-line replacement (dev#409)" do
    Given
    lock(image_pin("snappy-linux"))
    runner = runner({ "build" => { "run" => "./bin/build.sh", "runs_on" => "snappy-linux" }, "editor" => { "run" => "./bin/editor.sh", "runs_on" => "host" } })
    Kernel.expects(:exec).never
    Kernel.expects(:exit).with(1).once

    When
    runner.run(["build"])

    Then
    @stderr.string.include?("`runs_on:` is `environment:`")
    @stderr.string.include?("commands.build.runs_on: \"snappy-linux\" → `environment: snappy-linux`")
    @stderr.string.include?("commands.editor.runs_on: \"host\" → `environment: host`")
  end

  test "whatever the lock pins, container: and every build.container.* key are refused at load with their migration" do
    Given "a lock pinning no image under a dev.yml still on the old shape — the Dockerfile path it was on is gone"
    lock(Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build, version: "3.31", hash: "SHA256=0", metadata: {}))
    (@root / "Dockerfile").write("FROM --platform=linux/amd64 ubuntu:24.04\n")
    runner = runner(
      { "build" => { "run" => "./bin/build.sh" }, "editor" => { "run" => "./bin/editor.sh", "container" => false } },
      build: { "container" => { "image" => "snappy-linux", "registry" => "jpduchesne89", "persist" => true,
                                "volumes" => ["/e:/ue"], "resources" => { "cpus" => 8 } } },
    )
    Kernel.expects(:exec).never
    Kernel.expects(:exit).with(1).once

    When
    runner.run(["build"])

    Then "one message: each retired key and where it goes"
    @stderr.string.include?("declare an `image` block in dependencies.rb")
    @stderr.string.include?("build.container.image → delete it")
    @stderr.string.include?("build.container.registry → delete it")
    @stderr.string.include?("build.container.persist → `persist true` in the `image` block")
    @stderr.string.include?("build.container.volumes → `volume \"…\"` lines in the `image` block")
    @stderr.string.include?("build.container.resources → `engine:` at the top level of dev.yml")
    @stderr.string.include?("commands.editor.container: false → `environment: host`")
  end

  private

  # The fake engine's answer to each docker call (see setup). A method, not
  # a block: RSpock's source rewrite gives one-parameter blocks a trailing
  # comma, which splats an Array argument.
  def docker_succeeds?(args)
    args.first(2) != ["container", "inspect"]
  end

  # Whether a recorded docker call created a persistent service container.
  def service_create?(args)
    args.first(2) == ["run", "-d"]
  end

  # Run a command whose exec is faked: the recorded exec "returns", which
  # the executor's never-returns contract reports — expected here.
  def exec!(runner, argv)
    runner.run(argv)
  rescue Dev::ProjectExecutor::ExecReturnedError
    nil
  end

  # Record every exec's argv (the env dropped) instead of execing.
  def record_execs
    execs = []
    Kernel.stubs(:exec).with { |_env, *argv| execs << argv }
    execs
  end

  # A Runner over a dev.yml written into the fixture root, on a bare host
  # (no marker: nothing is native here).
  def runner(commands, build: nil, targets: nil, ui: fake_ui, out: StringIO.new)
    yaml = { "name" => "fixture", "commands" => commands }
    yaml["build"] = build if build
    yaml["targets"] = targets if targets
    (@root / "dev.yml").write(YAML.dump(yaml))
    host_rule = Dev::HostRule.new(host_environment: Dev::HostEnvironment.new(path: (@root / "no-marker").to_s))
    Dev::Runner.new(dev_yaml_path: @root / "dev.yml", ui:, out:, host_rule:, hosts_factory: method(:remote_hosts).to_proc)
  end

  # The project's container over the fake engine — a host whose gh holds
  # no login, so the developer's own token never enters an expected argv;
  # the repo named without gh — and a sync step that pushes nothing.
  def remote_hosts(project)
    Dev::Runner::RemoteHosts.new(
      containers: Dev::ProjectContainer.new(
        project_root: project.root, engine_hint: project.engine, client: Dev::BuildContainer.new(engine: @engine),
        github_token: Dev::ContainerGithubToken.new(source: -> { nil }), repo_resolver: -> { "o/r" },
      ),
      sync: ScriptedRemote::CannedSync.new,
    )
  end

  # Lock the pins and return their images.
  def lock(*pins)
    Dev::Deps::Lockfile.new(dir: @root).lock(Dev::EnvironmentImage.stamp(pins))
    Dev::Deps::Lockfile.new(dir: @root).read.select { |pin| pin.integration == :image }
      .map { |pin| Dev::EnvironmentImage.from_pin(pin) }
  end

  def image_pin(name, extra = {})
    Dev::Deps::Dependency.new(
      name: name, integration: :image, group: :app, version: "ue5.8-3", hash: "SHA256=#{"a" * 64}",
      metadata: {
        "from" => "ghcr.io/d3mlabs/unreal-engine-build-base", "platform" => "linux/amd64",
        "platforms" => ["linux/amd64"], "registry" => "ghcr.io/d3mlabs", "apt" => [],
      }.merge(extra),
    )
  end

  def fake_ui
    ui = typed_mock(Dev::Ui)
    ui.stubs(:print_header)
    ui.stubs(:print_remote_crossing)
    ui
  end
end

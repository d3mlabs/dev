# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/container_github_token"
require "dev"
require "dev/container_engine"
require "dev/deps"
require "dev/deps/dependency"
require "dev/deps/lockfile"
require "dev/environment_image"
require "dev/platform"
require "dev/runner"
require "dev/shadowenv_llvm"
require "support/fake_container_engine"
require "fileutils"
require "pathname"
require "stringio"
require "tmpdir"
require "yaml"

# dev#307's done-when, through the composition root: a checkout whose lock
# pins two images and whose dev.yml places each command by name. The
# process boundaries are faked — the engine (the image is "found locally",
# so no registry is reached), the exec — and everything between dev.yml
# and the argv dev would exec is real.
transform!(RSpock::AST::Transformation)
class RunsOnIntegrationTest < Minitest::Test
  include SorbetHelper

  COMMANDS = {
    "build" => { "run" => "./bin/build.sh", "runs_on" => "snappy-linux" },
    "test-server" => { "run" => "./bin/test-server.sh", "runs_on" => "snappy-server" },
    "editor" => { "run" => "./bin/editor.sh", "runs_on" => "host" },
    "lint" => { "run" => "./bin/lint.sh" },
  }.freeze

  def setup
    @original_cwd = Dir.pwd
    @root = Pathname(Dir.mktmpdir("runs-on-fixture"))
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

    When "each command is run"
    exec!(runner, ["build"])
    exec!(runner, ["test-server"])
    created = @engine.runs.find(&method(:service_create?))
    mounts = created.each_cons(2).select { |flag, _| flag == "-v" }.map(&:last)

    Then "build is a one-shot run of the linux image; test-server an exec into the server image's persistent container, created with its volume"
    execs.size == 2
    execs[0].first(3) == ["docker", "run", "--rm"]
    execs[0].last(6) == ["-w", "/project", linux.ref, "sh", "-c", "./bin/build.sh"]
    execs[1] == ["docker", "exec", "-w", "/project", Dev::BuildContainer.service_container_name(server.ref, @root), "sh", "-c", "./bin/test-server.sh"]
    created.include?(server.ref)
    mounts.include?("/e:/ue")
  end

  test "runs_on: host runs the command here, whatever the lock pins" do
    Given
    lock(image_pin("snappy-linux"), image_pin("snappy-server"))
    runner = runner(COMMANDS)

    When
    exec!(runner, ["editor"])

    Then "shadowenv exec on this host, no docker"
    1 * Kernel.exec(has_entries("RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", includes("./bin/editor.sh"))
  end

  test "a command naming none fails with both names listed" do
    Given
    lock(image_pin("snappy-linux"), image_pin("snappy-server"))
    runner = runner(COMMANDS)
    Kernel.expects(:exec).never
    Kernel.expects(:exit).with(1).once

    When
    runner.run(["lint"])

    Then "the refusal names the command's run line, both images, and the key to add"
    @stderr.string.include?("`./bin/lint.sh` runs in a container but names no image")
    @stderr.string.include?("snappy-linux, snappy-server")
    @stderr.string.include?("runs_on: <name>")
  end

  test "a command naming an image the lock does not pin is refused with what it does pin" do
    Given
    lock(image_pin("snappy-linux"), image_pin("snappy-server"))
    runner = runner({ "deploy" => { "run" => "./bin/deploy.sh", "runs_on" => "snappy-srv" } })
    Kernel.expects(:exec).never
    Kernel.expects(:exit).with(1).once

    When
    runner.run(["deploy"])

    Then
    @stderr.string.include?("`./bin/deploy.sh` runs on `snappy-srv`")
    @stderr.string.include?("snappy-linux, snappy-server")
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
    @stderr.string.include?("commands.editor.container: false → `runs_on: host`")
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

  # A Runner over a dev.yml written into the fixture root.
  def runner(commands, build: nil)
    yaml = { "name" => "fixture", "commands" => commands }
    yaml["build"] = build if build
    (@root / "dev.yml").write(YAML.dump(yaml))
    # A host whose gh holds no login, so the developer's own token never
    # enters an expected argv.
    Dev::Runner.new(dev_yaml_path: @root / "dev.yml", ui: fake_ui, out: StringIO.new,
      github_token: Dev::ContainerGithubToken.new(source: -> { nil }))
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
    ui = typed_mock(Dev::Cli::Ui)
    ui.stubs(:print_header)
    ui
  end
end

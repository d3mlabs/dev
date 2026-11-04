# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/command_runner"
require "dev/credentials"
require "dev/build_container"
require "dev/engine_resources"
require "dev/engine_resources_check"
require "dev/settings"
require "dev/shadowenv_llvm"
require "dev/shadowenv_python"
require "dev/shadowenv_ruby"
require "dev/deps/dependency"
require "dev/deps/lockfile"
require "dev/environment_image"
require "dev/environment_ref"
require "dev/host_environment"
require "dev/host_rule"
require "dev/project_images"
require "support/fake_container_engine"

transform!(RSpock::AST::Transformation)
class CommandRunnerTest < Minitest::Test
  extend T::Sig
  include SorbetHelper

  def setup
    @ui = typed_mock(Dev::Cli::Ui)
    @ui.stubs(:print_header)
    @ui.stubs(:print_crossing)
    # CommandRunner#run chdirs into @project_root, which teardown deletes.
    # Each test restores @original_cwd in its Cleanup block so later tests
    # don't run from a deleted directory (getcwd would raise ENOENT).
    @original_cwd = Dir.pwd
    @project_root = Pathname(Dir.mktmpdir("dev-runner-test"))
    @runner = Dev::CommandRunner.new(ui: @ui, project_root: @project_root, github_token: no_github_token)
    @runner.stubs(:ensure_shadowenv_provisioned!)
  end

  def teardown
    FileUtils.rm_rf(@project_root) if @project_root&.exist?
  end

  # A containerized runner with its engine-injected BuildContainer client
  # injected, so tests stub the client instance instead of class methods.
  # The project is on the lock's pins alone (lock_images). The marker is
  # the host rule's fact: absent unless a test writes one (`marker:` a
  # path under the project root). The engine-floor gate passes unless a
  # test hands in its own check (`resources_check:`) over a sized engine
  # (`engine:`).
  def container_runner(engine_hint: nil, engine: FakeContainerEngine.new, resources_check: passing_check,
    inside_container: false, marker: nil, github_token: no_github_token)
    client = Dev::BuildContainer.new(engine:)
    runner = Dev::CommandRunner.new(
      ui: @ui, project_root: @project_root, engine_hint:, resources_check:, container_client: client,
      host_rule: host_rule(marker:, inside_container:), github_token:,
    )
    [runner, client]
  end

  # A project command bound against the lock as it stands now — what the
  # composition root hands the runner (PlacementBinder): the runner reads
  # the placement, it never resolves a name. Call it after lock_images.
  def command(run, repl: false, environment: nil)
    ref = environment && Dev::EnvironmentRef.parse(environment)
    Dev::ProjectCommand.new(run:, repl:).with_placement(images.bind(ref, subject: run))
  end

  # A gate that passes whatever it is shown; tests about the gate pass a
  # real one over hermetic settings.
  def passing_check
    typed_mock(Dev::EngineResourcesCheck).tap { |check| check.stubs(:check!) }
  end

  def real_check
    Dev::EngineResourcesCheck.new(settings: Dev::Settings.new(
      config_path: (@project_root / "user-config.yml").to_s, system_config_path: (@project_root / "system-config.yml").to_s,
    ))
  end

  # An engine whose `docker info` reports the given size.
  def engine_sized(cpus:, memory_gib:)
    FakeContainerEngine.new(kind: :docker, capture_result: "#{cpus} #{memory_gib * 1_073_741_824}")
  end

  DOCKER_INFO = ["info", "--format", "{{.NCPU}} {{.MemTotal}}"].freeze

  # A host whose gh holds no login: the default for these tests, so the
  # developer's own `gh auth token` never leaks into an expectation.
  def no_github_token = Dev::ContainerGithubToken.new(source: -> { nil })

  def host_github_token(token) = Dev::ContainerGithubToken.new(source: -> { token })

  def host_rule(marker: nil, inside_container: false)
    path = marker || (@project_root / "no-marker").to_s
    Dev::HostRule.new(host_environment: Dev::HostEnvironment.new(path: path), inside_container:)
  end

  # Write the marker a host provisioned from +image+ carries; returns its path.
  def provisioned_from(image)
    path = @project_root / "etc-dev-environment"
    path.write(image.marker)
    path.to_s
  end

  def images
    Dev::ProjectImages.new(root: @project_root)
  end

  # Lock the project to these image pins (dev#277), each on linux/amd64.
  # What the (mocked) container client answers: a docker argv and the env
  # its bare `-e NAME` flags resolve in (dev#317).
  def invocation(*argv, env: {})
    Dev::BuildContainer::Invocation.new(argv: argv, env: env)
  end

  def lock_images(*names, persist: false, volumes: [], run_env: {})
    pins = names.map do |name|
      metadata = {
        "from" => "ghcr.io/d3mlabs/unreal-engine-build-base", "platform" => "linux/amd64",
        "platforms" => ["linux/amd64"], "registry" => "ghcr.io/d3mlabs", "apt" => [],
      }
      metadata["persist"] = true if persist
      metadata["volumes"] = volumes.dup unless volumes.empty?
      metadata["run_env"] = run_env.dup unless run_env.empty?
      Dev::Deps::Dependency.new(
        name: name, integration: :image, group: :app, version: "ue5.8-3", hash: "SHA256=#{"a" * 64}", metadata: metadata,
      )
    end
    Dev::Deps::Lockfile.new(dir: @project_root).lock(Dev::EnvironmentImage.stamp(pins))
  end

  # --- Child env ---

  # The direct run is a second `shadowenv exec` spawn beside ShadowenvExec
  # and, like it, clears nothing: env hygiene is bin/dev's, once, at the
  # entrypoint. The exact hash is pinned so a nil'd key — the per-spawn
  # scrub that regressed this path with dev#274's LoadError (dev#333) —
  # cannot creep back in unnoticed.
  test "a direct run hands its child the inherited env plus dev's lib on RUBYLIB, and clears nothing" do
    Given "a runner over a project, with no RUBYLIB of the suite's own in the way"
    saved_rubylib = ENV.delete("RUBYLIB")
    runner = Dev::CommandRunner.new(ui: @ui, project_root: @project_root)
    runner.stubs(:ensure_shadowenv_provisioned!)
    Kernel.stubs(:exec)
    cmd = command("./bin/console", repl: true)

    When "we run a command"
    runner.exec_into(cmd)

    Then "the child's env is dev's lib on RUBYLIB and nothing else — no key nil'd"
    1 * Kernel.exec(
      { "RUBYLIB" => Dev::DEV_LIB_DIR.to_s },
      "shadowenv", "exec", "--", "sh", "-c", "./bin/console"
    )

    Cleanup
    ENV["RUBYLIB"] = saved_rubylib if saved_rubylib
    Dir.chdir(@original_cwd)
  end

  # --- Toolchain provisioning ---

  test "run provisions nothing for the interpreters: Ruby and Python are dependencies dev deps install activated" do
    Given "a runner whose provisioning step is not stubbed, on a host that needs no LLVM"
    runner = Dev::CommandRunner.new(ui: @ui, project_root: @project_root)
    Dev::ShadowenvLlvm.stubs(:ci_or_linux?).returns(true)
    Kernel.stubs(:exec)
    cmd = command("./bin/console", repl: true)

    When "we run a command"
    runner.exec_into(cmd)

    Then "no interpreter is resolved, built or activated on the way to the exec"
    0 * Dev::ShadowenvRuby.activate!(keg: anything, version: anything, project_root: anything)
    0 * Dev::ShadowenvPython.activate!(keg: anything, version: anything, project_root: anything)
    1 * Kernel.exec(has_entries("RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", "./bin/console")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "run provisions the host LLVM when the project needs it" do
    Given "a runner whose provisioning step is not stubbed, over a project that needs LLVM"
    runner = Dev::CommandRunner.new(ui: @ui, project_root: @project_root)
    Dev::ShadowenvLlvm.stubs(:ci_or_linux?).returns(false)
    Dev::ShadowenvLlvm.stubs(:project_needs_llvm?).with(@project_root).returns(true)
    Dev::ShadowenvLlvm.stubs(:detect_llvm_prefix).returns("/opt/llvm")
    Dev::ShadowenvLlvm.stubs(:provisioned?).with("/opt/llvm", project_root: @project_root).returns(false)
    Kernel.stubs(:exec)
    cmd = command("./bin/console", repl: true)

    When "we run a command"
    runner.exec_into(cmd)

    Then "the LLVM shadowenv is set up for the project root"
    1 * Dev::ShadowenvLlvm.setup!(project_root: @project_root, llvm_prefix: "/opt/llvm")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  # --- Local execution (no container) ---

  test "run prints header and execs directly when repl" do
    Given "a repl command"
    cmd = command("./bin/console", repl: true)

    When "we run the command"
    @runner.exec_into(cmd)

    Then "header is printed and process is replaced via exec"
    1 * @ui.print_header("./bin/console")
    1 * Kernel.exec(has_entries("RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", "./bin/console")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "run prints header and execs with args when repl" do
    Given "a repl command with args"
    cmd = command("./bin/console", repl: true)

    When "we run the command with extra args"
    @runner.exec_into(cmd, args: ["--verbose"])

    Then "header includes args and exec passes them through"
    1 * @ui.print_header("./bin/console --verbose")
    1 * Kernel.exec(has_entries("RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", "./bin/console --verbose")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "run prints header and execs with shell wrapper for non-repl" do
    Given "a non-repl command"
    cmd = command("./bin/setup.rb", repl: false)

    When "we run the command"
    @runner.exec_into(cmd)

    Then "header is printed and exec is called with a shell wrapper"
    1 * @ui.print_header("./bin/setup.rb")
    1 * Kernel.exec(has_entries("RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", includes("./bin/setup.rb"))

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "non-repl shell wrapper includes status check and Done message" do
    Given "a non-repl command"
    cmd = command("./bin/test.sh", repl: false)

    When "we run the command"
    @runner.exec_into(cmd)

    Then "the shell wrapper includes exit code handling and Done/Failed output"
    1 * Kernel.exec(has_entries("RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c",
      all_of(includes("./bin/test.sh"), includes("__dev_status=$?"), includes("Done"), includes("Failed")))

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "non-repl shell wrapper includes args" do
    Given "a non-repl command with args"
    cmd = command("./bin/test.sh", repl: false)

    When "we run with args"
    @runner.exec_into(cmd, args: ["-v"])

    Then "header and wrapper both include args"
    1 * @ui.print_header("./bin/test.sh -v")
    1 * Kernel.exec(has_entries("RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", includes("./bin/test.sh -v"))

    Cleanup
    Dir.chdir(@original_cwd)
  end

  # --- run_waiting (spawn-and-wait for callers with post-execute steps) ---

  test "run_waiting spawns and waits instead of exec-replacing the process" do
    Given "a non-repl command"
    cmd = command("./bin/setup.rb", repl: false)

    When "we run the command waiting"
    @runner.run_waiting(cmd)

    Then "the command runs as a waited child, never via exec"
    1 * Kernel.system(has_entries("RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", includes("./bin/setup.rb")) >> true
    0 * Kernel.exec(any_parameters)

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "run_waiting raises CommandFailedError carrying the child's exit status" do
    Given "a child that exits 7"
    cmd = command("./bin/setup.rb", repl: false)
    Kernel.stubs(:system).returns(false)
    # Kernel.system is stubbed, so wait on a real child here to leave the
    # thread-local $? at exit status 7 — what a real failed child would set.
    Process.wait(Process.spawn("sh", "-c", "exit 7"))

    When "we run the command waiting"
    error = assert_raises(Dev::CommandRunner::CommandFailedError) { @runner.run_waiting(cmd) }

    Then "the error carries the child's exit status"
    error.exit_status == 7

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "run_waiting raises CommandKilledError carrying the terminating signal" do
    Given "a child killed by SIGTERM"
    cmd = command("./bin/setup.rb", repl: false)
    Kernel.stubs(:system).returns(false)
    # Kernel.system is stubbed, so wait on a real signal-killed child here to
    # leave the thread-local $? signaled — what a real killed child would set.
    Process.wait(Process.spawn("sh", "-c", "kill -TERM $$"))

    When "we run the command waiting"
    error = assert_raises(Dev::CommandRunner::CommandKilledError) { @runner.run_waiting(cmd) }

    Then "the error carries the terminating signal number"
    error.signal == Signal.list.fetch("TERM")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "run_waiting raises CommandSpawnError when the child never started" do
    Given "a child that cannot be spawned"
    cmd = command("./bin/setup.rb", repl: false)
    # Kernel.system returns nil (not false) when the child never started.
    Kernel.stubs(:system).returns(nil)

    When "we run the command waiting"
    @runner.run_waiting(cmd)

    Then
    raises Dev::CommandRunner::CommandSpawnError

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "run_waiting runs the containerized command spawn-and-wait" do
    Given "a runner over a lock pinning one image"
    lock_images("myapp-linux")
    runner, client = container_runner
    cmd = command("./bin/up.sh", repl: false)

    When "the image resolves and we run the command waiting"
    client.stubs(:ensure_environment_image!).returns("ghcr.io/d3mlabs/myapp-linux:deadbeef")
    client.stubs(:docker_run_command)
      .returns(invocation("docker", "run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/up.sh"))
    runner.run_waiting(cmd)

    Then "docker runs as a waited child under the engine's env, never via exec"
    1 * Kernel.system({}, "docker", "run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/up.sh") >> true
    0 * Kernel.exec(any_parameters)

    Cleanup
    Dir.chdir(@original_cwd)
  end

  # --- Container execution ---

  test "run resolves a pinned image through ensure_environment_image! and runs in it: the one image, no key needed" do
    Given "a lock pinning one image"
    lock_images("myapp-linux")
    runner, client = container_runner
    cmd = command("./bin/build.sh", repl: false)
    client.expects(:ensure_environment_image!).once
      .with { |image, publish:| image.name == "myapp-linux" && !publish }
      .returns("ghcr.io/d3mlabs/myapp-linux:deadbeef")
    client.expects(:docker_run_command)
      .with("ghcr.io/d3mlabs/myapp-linux:deadbeef", project_root: @project_root, shell_cmd: "./bin/build.sh", volumes: [], env: {})
      .returns(invocation("docker", "run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/build.sh"))

    When
    runner.exec_into(cmd)

    Then
    1 * Kernel.exec({}, "docker", "run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/build.sh")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  # --- The engine-floor gate (dev#400) ---
  #
  # No provisioner runs on this path, so the runner owns the gate: one
  # `docker info`, live, before the image is reached for — and none inside
  # the image step. The spawn shape is pinned so a second read cannot creep
  # back into BuildContainer.

  test "a containerized command measures the engine against the project's floor once, before the image is reached for" do
    Given "a lock pinning one image, a 12/24 engine, and a hint it meets"
    lock_images("myapp-linux")
    engine = engine_sized(cpus: 12, memory_gib: 24)
    runner, client = container_runner(engine:, engine_hint: Dev::EngineResources::Hint.new(cpus: 8, memory_gib: 16),
      resources_check: real_check)
    client.stubs(:docker_run_command)
      .returns(invocation("docker", "run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/build.sh"))

    When "the command runs"
    runner.exec_into(command("./bin/build.sh", repl: false))

    Then "one docker info, then the image's inspect — nothing measured twice"
    engine.captures == [DOCKER_INFO]
    engine.runs.map(&:first) == ["image"]
    1 * Kernel.exec({}, "docker", "run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/build.sh")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "a containerized command on an undersized engine is refused before any image work" do
    Given "a lock pinning one image, a 4/8 engine, and a 12/24 floor, with the machine's own escape hatch out of the way"
    saved_mode = ENV.delete("DEV_ENGINE_RESOURCES")
    lock_images("myapp-linux")
    engine = engine_sized(cpus: 4, memory_gib: 8)
    runner, client = container_runner(engine:, engine_hint: Dev::EngineResources::Hint.new(cpus: 12, memory_gib: 24),
      resources_check: real_check)
    client.expects(:docker_run_command).never
    Kernel.expects(:exec).never

    When "the command runs"
    runner.exec_into(command("./bin/build.sh", repl: false))

    Then "the gate's verdict is the run's verdict, and the image was never inspected, pulled or built"
    error = raises Dev::EngineResourcesCheck::UndersizedEngineError
    error.message.include?("4 cpus / 8 GiB")
    error.message.include?("12 cpus / 24 GiB")
    engine.captures == [DOCKER_INFO]
    engine.runs.empty?

    Cleanup
    ENV["DEV_ENGINE_RESOURCES"] = saved_mode if saved_mode
    Dir.chdir(@original_cwd)
  end

  test "a project declaring no floor never asks the daemon its size" do
    Given "a lock pinning one image and no hint"
    lock_images("myapp-linux")
    engine = FakeContainerEngine.new(kind: :docker, capture_result: ->(_args) { raise "docker info was called" })
    runner, client = container_runner(engine:, engine_hint: nil, resources_check: real_check)
    client.stubs(:docker_run_command)
      .returns(invocation("docker", "run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/build.sh"))

    When "the command runs"
    runner.exec_into(command("./bin/build.sh", repl: false))

    Then
    engine.captures.empty?
    1 * Kernel.exec({}, "docker", "run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/build.sh")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "a host command never measures the engine: no container is reached for" do
    Given "two pinned images, a floor, and a command placed on the host"
    lock_images("snappy-linux", "snappy-server")
    engine = FakeContainerEngine.new(kind: :docker, capture_result: ->(_args) { raise "docker info was called" })
    runner, client = container_runner(engine:, engine_hint: Dev::EngineResources::Hint.new(cpus: 12), resources_check: real_check)
    client.expects(:ensure_environment_image!).never

    When
    runner.exec_into(command("./bin/editor.sh", repl: false, environment: "host"))

    Then
    engine.captures.empty?
    1 * Kernel.exec(has_entries("RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", includes("./bin/editor.sh"))

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "environment: picks the image among several, and the block's shape rides it: persist, volumes, run_env" do
    Given "two pinned images; the command names the persisted one"
    lock_images("snappy-linux", "snappy-server", persist: true, volumes: ["/e:/ue"], run_env: { "WWISE_TOKEN" => "wwise/token" })
    ENV["WWISE_TOKEN"] = "tok-123"
    runner, client = container_runner
    cmd = command("./bin/test-server.sh", repl: false, environment: "snappy-server")
    client.expects(:ensure_environment_image!).once
      .with { |image, **| image.name == "snappy-server" }
      .returns("ghcr.io/d3mlabs/snappy-server:deadbeef")
    client.expects(:ensure_service!)
      .with("ghcr.io/d3mlabs/snappy-server:deadbeef", project_root: @project_root, volumes: ["/e:/ue"])
      .returns("dev-snappy-server-deadbeef")
    client.expects(:docker_exec_command)
      .with("dev-snappy-server-deadbeef", shell_cmd: "./bin/test-server.sh", env: { "WWISE_TOKEN" => "tok-123" })
      .returns(invocation("docker", "exec", "dev-snappy-server-deadbeef", "sh", "-c", "./bin/test-server.sh"))
    client.expects(:docker_run_command).never

    When
    runner.exec_into(cmd)

    Then
    1 * Kernel.exec({}, "docker", "exec", "dev-snappy-server-deadbeef", "sh", "-c", "./bin/test-server.sh")

    Cleanup
    ENV.delete("WWISE_TOKEN")
    Dir.chdir(@original_cwd)
  end

  test "environment: host runs on this host whatever the lock pins" do
    Given "two pinned images and a command placed on the host"
    lock_images("snappy-linux", "snappy-server")
    runner, client = container_runner
    runner.stubs(:ensure_shadowenv_provisioned!)
    cmd = command("./bin/editor.sh", repl: false, environment: "host")
    client.expects(:ensure_environment_image!).never

    When
    runner.exec_into(cmd)

    Then
    1 * Kernel.exec(has_entries("RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", includes("./bin/editor.sh"))

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "a command the composition root left unbound is refused before anything runs: the runner never resolves a name" do
    Given "a pinned image and a command straight from the parser"
    lock_images("snappy-linux")
    runner, client = container_runner
    client.expects(:ensure_environment_image!).never
    Kernel.expects(:exec).never

    When
    runner.exec_into(Dev::ProjectCommand.new(run: "./bin/build.sh", repl: false))

    Then
    error = raises(Dev::ProjectCommand::UnboundPlacementError)
    error.message.include?("dev deps update")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "one dim crossing line is printed when a command enters a container, and none on a host or native run" do
    Given "two images; a host provisioned from one; a command on each, and one on the host"
    lock_images("snappy-linux", "snappy-server")
    server = images.named("snappy-server")
    runner, client = container_runner(marker: provisioned_from(server))
    runner.stubs(:ensure_llvm_provisioned!)
    client.stubs(:ensure_environment_image!).returns("ref-linux")
    client.stubs(:docker_run_command).returns(invocation("docker", "run", "--rm", "ref-linux", "sh", "-c", "./bin/build.sh"))
    Kernel.stubs(:exec)

    When
    runner.exec_into(command("./bin/build.sh", environment: "snappy-linux"))
    runner.exec_into(command("./bin/server.sh", environment: "snappy-server"))
    runner.exec_into(command("./bin/editor.sh", environment: "host"))

    Then "the crossing into snappy-linux's container is the one line"
    1 * @ui.print_crossing("snappy-linux")
    0 * @ui.print_crossing("snappy-server")
    0 * @ui.print_crossing("host")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "the host rule is asked of the command's image: a host provisioned from one image runs that command here, the other's in a container" do
    Given "two linux/amd64 images, on a host whose marker is one of them"
    lock_images("snappy-linux", "snappy-server")
    pins = images.pinned
    server = pins.find { |image| image.name == "snappy-server" }
    runner, client = container_runner(marker: provisioned_from(server))
    runner.stubs(:ensure_llvm_provisioned!)
    client.expects(:ensure_environment_image!).once.with { |image, **| image.name == "snappy-linux" }.returns("ref-linux")
    client.expects(:docker_run_command).once.returns(invocation("docker", "run", "--rm", "ref-linux", "sh", "-c", "./bin/build.sh"))

    When "one command runs on each"
    runner.exec_into(command("./bin/server.sh", repl: false, environment: "snappy-server"))
    runner.exec_into(command("./bin/build.sh", repl: false, environment: "snappy-linux"))

    Then "the server command execs under the host's shadowenv; the linux one in docker, though the host is its platform too"
    1 * Kernel.exec(has_entries("RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", includes("./bin/server.sh"))
    1 * Kernel.exec({}, "docker", "run", "--rm", "ref-linux", "sh", "-c", "./bin/build.sh")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "a host provisioned from nothing is never native: no marker, the container" do
    Given "a linux/amd64 image on a host with no marker"
    lock_images("snappy-linux")
    runner, client = container_runner
    client.expects(:ensure_environment_image!).once.returns("ref-linux")
    client.expects(:docker_run_command).once.returns(invocation("docker", "run", "--rm", "ref-linux", "sh", "-c", "./bin/build.sh"))

    When
    runner.exec_into(command("./bin/build.sh", repl: false))

    Then
    1 * Kernel.exec({}, "docker", "run", "--rm", "ref-linux", "sh", "-c", "./bin/build.sh")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "a host provisioned from an older recipe of the image has drifted: the command runs in the lock's image" do
    Given "the marker names the image under another digest"
    lock_images("snappy-linux")
    current = images.pinned.first
    older = Dev::EnvironmentImage.new(
      name: current.name, from: current.from, from_digest: current.from_digest, platform: current.platform,
      apt: ["libnss3"], registry: current.registry,
    )
    runner, client = container_runner(marker: provisioned_from(older))
    client.expects(:ensure_environment_image!).once.returns("ref-linux")
    client.expects(:docker_run_command).once.returns(invocation("docker", "run", "--rm", "ref-linux", "sh", "-c", "./bin/build.sh"))

    When
    runner.exec_into(command("./bin/build.sh", repl: false))

    Then
    1 * Kernel.exec({}, "docker", "run", "--rm", "ref-linux", "sh", "-c", "./bin/build.sh")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "inside a container of the lock's image, the image's command runs directly" do
    Given
    lock_images("snappy-linux")
    runner, client = container_runner(inside_container: true, marker: provisioned_from(images.pinned.first))
    client.expects(:docker_run_command).never

    When
    runner.exec_into(command("./bin/build.sh", repl: false))

    Then
    1 * Kernel.exec(has_entries("RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", includes("./bin/build.sh"))

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "inside a container that is not the lock's image, the command is refused: the container cannot replace itself" do
    Given "a container made from an older recipe"
    lock_images("snappy-linux")
    current = images.pinned.first
    older = Dev::EnvironmentImage.new(
      name: current.name, from: current.from, from_digest: current.from_digest, platform: current.platform,
      apt: ["libnss3"], registry: current.registry,
    )
    runner, client = container_runner(inside_container: true, marker: provisioned_from(older))
    client.expects(:docker_run_command).never
    Kernel.expects(:exec).never

    When
    error = assert_raises(Dev::HostRule::ContainerDriftError) do
      runner.exec_into(command("./bin/build.sh", repl: false))
    end

    Then
    error.message.include?("this container is snappy-linux@#{older.short_digest}")
    error.message.include?("the lock's snappy-linux is snappy-linux@#{current.short_digest}")
    error.message.include?("dev container reset && dev up")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "inside the container, a repl command execs bare under shadowenv, and the host-only LLVM is not provisioned" do
    Given "an inside runner and a repl command"
    runner = Dev::CommandRunner.new(ui: @ui, project_root: @project_root, host_rule: host_rule(inside_container: true))
    cmd = command("./bin/console", repl: true)

    When "we run the command"
    runner.exec_into(cmd)

    Then "the argv is shadowenv exec, sh -c and the command alone; llvm is the image's concern"
    0 * Dev::ShadowenvLlvm.setup!(project_root: anything, llvm_prefix: anything)
    1 * Kernel.exec(has_entries("RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", "./bin/console")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "run falls back to local execution when the lock pins no image" do
    Given "a runner over a project pinning no image"
    runner = Dev::CommandRunner.new(ui: @ui, project_root: @project_root)
    runner.stubs(:ensure_shadowenv_provisioned!)
    cmd = command("./bin/build.sh", repl: false)

    When "we run the command"
    runner.exec_into(cmd)

    Then "exec uses shadowenv"
    1 * Kernel.exec(has_entries("RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", includes("./bin/build.sh"))

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "container execution includes args in shell command" do
    Given "a pinned image and a command with args"
    lock_images("myapp-linux")
    runner, client = container_runner
    cmd = command("./bin/test.sh", repl: false)

    When "the client returns a docker command and we run with args"
    client.stubs(:ensure_environment_image!).returns("ghcr.io/d3mlabs/myapp-linux:deadbeef")
    client.expects(:docker_run_command)
      .with("ghcr.io/d3mlabs/myapp-linux:deadbeef", project_root: @project_root, shell_cmd: "./bin/test.sh --verbose", volumes: [], env: {})
      .returns(invocation("docker", "run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/test.sh --verbose"))
    runner.exec_into(cmd, args: ["--verbose"])

    Then "the args are included in the shell command passed to docker"
    1 * @ui.print_header("./bin/test.sh --verbose")
    1 * Kernel.exec({}, "docker", "run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/test.sh --verbose")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "container execution injects run_env from ENV override" do
    Given "a pinned image declaring run_env and the ENV var set"
    lock_images("myapp-linux", run_env: { "WWISE_TOKEN" => "wwise/token" })
    runner, client = container_runner
    cmd = command("./bin/build.sh", repl: false)
    ENV["WWISE_TOKEN"] = "tok-123"

    When "the image is ready and the command runs"
    client.stubs(:ensure_environment_image!).returns("ghcr.io/d3mlabs/myapp-linux:deadbeef")
    client.expects(:docker_run_command)
      .with("ghcr.io/d3mlabs/myapp-linux:deadbeef", project_root: @project_root, shell_cmd: "./bin/build.sh", volumes: [], env: { "WWISE_TOKEN" => "tok-123" })
      .returns(invocation("docker", "run", "--rm", "-e", "WWISE_TOKEN", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/build.sh", env: { "WWISE_TOKEN" => "tok-123" }))
    runner.exec_into(cmd)

    Then "the argv names the variable; its value reaches docker through the spawn env, never argv (dev#317)"
    1 * Kernel.exec({ "WWISE_TOKEN" => "tok-123" }, "docker", "run", "--rm", "-e", "WWISE_TOKEN", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/build.sh")

    Cleanup
    ENV.delete("WWISE_TOKEN")
    Dir.chdir(@original_cwd)
  end

  test "container execution opts into publishing when DEV_PUBLISH_IMAGE is set" do
    Given "a pinned image and DEV_PUBLISH_IMAGE=1 in the env"
    lock_images("myapp-linux")
    runner, client = container_runner
    cmd = command("./bin/build.sh", repl: false)
    ENV["DEV_PUBLISH_IMAGE"] = "1"

    When "the command runs"
    client.expects(:ensure_environment_image!)
      .with { |image, publish:| image.name == "myapp-linux" && publish }
      .returns("ghcr.io/d3mlabs/myapp-linux:deadbeef")
    client.stubs(:docker_run_command).returns(invocation("docker", "run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/build.sh"))
    runner.exec_into(cmd)

    Then "ensure_environment_image! is asked to publish the resolved image"
    1 * Kernel.exec({}, "docker", "run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/build.sh")

    Cleanup
    ENV.delete("DEV_PUBLISH_IMAGE")
    Dir.chdir(@original_cwd)
  end

  test "a command run inside carries the host's gh token as GH_TOKEN, after the run_env" do
    Given "a host whose gh is logged in, and a pinned image with a run_env"
    lock_images("myapp-linux", run_env: { "WWISE_TOKEN" => "wwise/token" })
    runner, client = container_runner(github_token: host_github_token("gho_host"))
    cmd = command("./bin/ue/starter/publish.sh", repl: false)
    ENV["WWISE_TOKEN"] = "tok-123"

    When "the command runs"
    client.stubs(:ensure_environment_image!).returns("ghcr.io/d3mlabs/myapp-linux:deadbeef")
    client.expects(:docker_run_command)
      .with("ghcr.io/d3mlabs/myapp-linux:deadbeef", project_root: @project_root, shell_cmd: "./bin/ue/starter/publish.sh",
        volumes: [], env: { "WWISE_TOKEN" => "tok-123", "GH_TOKEN" => "gho_host" })
      .returns(invocation("docker", "run", "--rm", "-e", "WWISE_TOKEN", "-e", "GH_TOKEN", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/ue/starter/publish.sh",
        env: { "WWISE_TOKEN" => "tok-123", "GH_TOKEN" => "gho_host" }))
    runner.exec_into(cmd)

    Then "docker run gets both by name on argv; both values ride the spawn env, the token on no argv (dev#317)"
    1 * Kernel.exec({ "WWISE_TOKEN" => "tok-123", "GH_TOKEN" => "gho_host" }, "docker", "run", "--rm", "-e", "WWISE_TOKEN", "-e", "GH_TOKEN", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/ue/starter/publish.sh")

    Cleanup
    ENV.delete("WWISE_TOKEN")
    Dir.chdir(@original_cwd)
  end

  test "a GH_TOKEN the run_env names wins over the host's on a command run inside" do
    Given "a host whose gh is logged in, and a pinned image whose run_env names GH_TOKEN"
    lock_images("myapp-linux", run_env: { "GH_TOKEN" => "github/token" })
    runner, client = container_runner(github_token: host_github_token("gho_host"))
    cmd = command("./bin/build.sh", repl: false)
    ENV["GH_TOKEN"] = "gho_mine"

    When "the command runs"
    client.stubs(:ensure_environment_image!).returns("ghcr.io/d3mlabs/myapp-linux:deadbeef")
    client.expects(:docker_run_command)
      .with("ghcr.io/d3mlabs/myapp-linux:deadbeef", project_root: @project_root, shell_cmd: "./bin/build.sh",
        volumes: [], env: { "GH_TOKEN" => "gho_mine" })
      .returns(invocation("docker", "run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/build.sh"))
    runner.exec_into(cmd)

    Then "the run_env's token is the one injected"
    1 * Kernel.exec({}, "docker", "run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/build.sh")

    Cleanup
    ENV.delete("GH_TOKEN")
    Dir.chdir(@original_cwd)
  end

  test "container execution skips unresolvable run_env without prompting" do
    Given "a pinned image with run_env whose value is not in ENV or storage"
    lock_images("myapp-linux", run_env: { "WWISE_TOKEN" => "wwise/token" })
    runner, client = container_runner
    cmd = command("./bin/build.sh", repl: false)
    ENV.delete("WWISE_TOKEN")

    When "the credential is not stored and the command runs"
    Dev::Credentials.stubs(:load).with("wwise", "token").returns(nil)
    client.stubs(:ensure_environment_image!).returns("ghcr.io/d3mlabs/myapp-linux:deadbeef")
    client.expects(:docker_run_command)
      .with("ghcr.io/d3mlabs/myapp-linux:deadbeef", project_root: @project_root, shell_cmd: "./bin/build.sh", volumes: [], env: {})
      .returns(invocation("docker", "run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/build.sh"))
    runner.exec_into(cmd)

    Then "no env is injected and the command still runs"
    1 * Kernel.exec({}, "docker", "run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/build.sh")

    Cleanup
    Dir.chdir(@original_cwd)
  end
end

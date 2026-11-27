# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/command_runner"
require "dev/credentials"
require "dev/build_container"
require "dev/container_github_token"
require "dev/engine_resources"
require "dev/engine_resources_check"
require "dev/project_container"
require "dev/settings"
require "dev/shadowenv_llvm"
require "dev/shadowenv_python"
require "dev/shadowenv_ruby"
require "dev/deps/dependency"
require "dev/deps/lockfile"
require "dev/environment_image"
require "dev/environment_ref"
require "dev/host_environment"
require "dev/cli/host_rule"
require "dev/cli/project_images"
require "support/fake_container_engine"

transform!(RSpock::AST::Transformation)
class CommandRunnerTest < Minitest::Test
  extend T::Sig
  include SorbetHelper

  def setup
    @ui = typed_mock(Dev::Ui)
    # CommandRunner#run chdirs into @project_root, which teardown deletes.
    # Each test restores @original_cwd in its Cleanup block so later tests
    # don't run from a deleted directory (getcwd would raise ENOENT).
    @original_cwd = Dir.pwd
    @project_root = Pathname(Dir.mktmpdir("dev-runner-test"))
    @runner = Dev::Cli::CommandRunner.new(ui: @ui, project_root: @project_root, llvm: no_llvm_host)
  end

  # The host LLVM toolchain as a host that needs none: a typed fake whose
  # one answer short-circuits provisioning, so a run reaches its exec
  # without probing this machine (the two provisioning tests state the
  # toolchain's answers as interactions instead).
  #
  # @return [T.class_of(Dev::ShadowenvLlvm)]
  def no_llvm_host
    llvm = typed_mock(Dev::ShadowenvLlvm, class_of: true)
    llvm.define_singleton_method(:ci_or_linux?) { true }
    llvm
  end

  def teardown
    FileUtils.rm_rf(@project_root) if @project_root&.exist?
  end

  # A containerized runner over a real ProjectContainer whose
  # engine-injected BuildContainer client is handed back, so tests state
  # the client's answers as interactions (the image step is a registry
  # boundary) and read what reached the engine off the fake. The
  # container's transport delivers the tree as the checkout itself,
  # mounted (no git, no forge). The project is on the lock's pins alone
  # (lock_images). The marker is the host rule's fact: absent unless a
  # test writes one (`marker:` a path under the project root). The
  # engine-floor gate is a real check over hermetic settings; with no hint
  # (`engine_hint:` nil, the default) it measures nothing, so only tests
  # about the gate hand in a sized engine (`engine:`).
  def container_runner(engine_hint: nil, engine: FakeContainerEngine.new, resources_check: real_check,
    inside_container: false, marker: nil, github_token: no_github_token)
    client = Dev::BuildContainer.new(engine:)
    containers = Dev::ProjectContainer.new(project_root: @project_root, client:, engine_hint:, resources_check:, github_token:)
    runner = Dev::Cli::CommandRunner.new(
      ui: @ui, project_root: @project_root, host_rule: host_rule(marker:, inside_container:), containers:, llvm: no_llvm_host,
    )
    [runner, client]
  end

  # A shell command as the container runs it: the argv a stubbed client
  # must have been handed, `sh -c` and the command, nothing between.
  def runs_inside(shell_command)
    ["sh", "-c", shell_command]
  end

  # A project command bound against the lock as it stands now — what the
  # composition root hands the runner (PlacementBinder): the runner reads
  # the placement, it never resolves a name. Call it after lock_images.
  def command(run, repl: false, environment: nil)
    ref = environment && Dev::EnvironmentRef.parse(environment)
    Dev::Cli::ProjectCommand.new(run:, repl:).with_placement(images.bind(ref, subject: run))
  end

  # The engine-floor gate over settings that never read this machine's.
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
  def no_github_token
    Dev::ContainerGithubToken.new(source: -> { nil })
  end

  def host_github_token(token)
    Dev::ContainerGithubToken.new(source: -> { token })
  end

  def host_rule(marker: nil, inside_container: false)
    path = marker || (@project_root / "no-marker").to_s
    Dev::Cli::HostRule.new(host_environment: Dev::HostEnvironment.new(path: path), inside_container:)
  end

  # Write the marker a host provisioned from +image+ carries; returns its path.
  def provisioned_from(image)
    path = @project_root / "etc-dev-environment"
    path.write(image.marker)
    path.to_s
  end

  def images
    Dev::Cli::ProjectImages.new(root: @project_root)
  end

  # What the (mocked) container client answers: the engine argv (its verb
  # onward) and the env its bare `-e NAME` flags resolve in (dev#317).
  def invocation(*argv, env: {})
    Dev::BuildContainer::Invocation.new(argv: argv, env: env)
  end

  # Lock the project to these image pins (dev#277), each on linux/amd64.
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
    runner = Dev::Cli::CommandRunner.new(ui: @ui, project_root: @project_root, llvm: no_llvm_host)
    cmd = command("./bin/console", repl: true)

    When "we run a command"
    runner.exec_into(cmd)

    Then "the child's env is dev's lib on RUBYLIB and nothing else — no key nil'd"
    _ * @ui.print_header
    1 * Kernel.exec(
      { "RUBYLIB" => Dev::DEV_LIB_DIR.to_s },
      "shadowenv", "exec", "--dir", @project_root.to_s, "--", "sh", "-c", "./bin/console"
    )

    Cleanup
    ENV["RUBYLIB"] = saved_rubylib if saved_rubylib
    Dir.chdir(@original_cwd)
  end

  # Inside the build container the checkout is the host's tree, and the
  # host's .shadowenv.d names the host's prefixes; the container's shadowenv
  # is the one nested under .shadowenv.d-container/ (ProjectShadowenv), so
  # the direct run points shadowenv there rather than at the project root.
  test "a direct run inside the build container points shadowenv at the container's nested shadowenv" do
    Given "a project and a command"
    cmd = command("./bin/console", repl: true)

    When "a runner built inside the container runs it"
    runner = Dev::Cli::CommandRunner.new(ui: @ui, project_root: @project_root, llvm: no_llvm_host)
    runner.exec_into(cmd)

    Then
    _ * Dev::ContainerContext.inside? >> true
    _ * @ui.print_header
    1 * Kernel.exec(has_entries("RUBYLIB" => anything), "shadowenv", "exec", "--dir", (@project_root / ".shadowenv.d-container").to_s, "--", "sh", "-c", "./bin/console")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  # --- Toolchain provisioning ---

  test "run provisions nothing for the interpreters: Ruby and Python are dependencies dev deps install activated" do
    Given "a runner over the host LLVM toolchain, on a host that needs no LLVM"
    llvm = typed_mock(Dev::ShadowenvLlvm, class_of: true)
    runner = Dev::Cli::CommandRunner.new(ui: @ui, project_root: @project_root, llvm: llvm)
    cmd = command("./bin/console", repl: true)

    When "we run a command"
    runner.exec_into(cmd)

    Then "no interpreter is resolved, built or activated on the way to the exec"
    _ * @ui.print_header
    1 * llvm.ci_or_linux? >> true
    0 * Dev::ShadowenvRuby.activate!(keg: anything, version: anything, project_root: anything)
    0 * Dev::ShadowenvPython.activate!(keg: anything, version: anything, project_root: anything)
    1 * Kernel.exec(has_entries("RUBYLIB" => anything), "shadowenv", "exec", "--dir", @project_root.to_s, "--", "sh", "-c", "./bin/console")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "run provisions the host LLVM when the project needs it" do
    Given "a runner over the host LLVM toolchain, over a project that needs LLVM"
    llvm = typed_mock(Dev::ShadowenvLlvm, class_of: true)
    runner = Dev::Cli::CommandRunner.new(ui: @ui, project_root: @project_root, llvm: llvm)
    cmd = command("./bin/console", repl: true)

    When "we run a command"
    runner.exec_into(cmd)

    Then "the toolchain is asked, and the LLVM shadowenv is set up for the project root"
    _ * @ui.print_header
    _ * Kernel.exec
    1 * llvm.ci_or_linux? >> false
    1 * llvm.project_needs_llvm?(@project_root) >> true
    1 * llvm.detect_llvm_prefix >> "/opt/llvm"
    1 * llvm.provisioned?("/opt/llvm", project_root: @project_root) >> false
    1 * llvm.setup!(project_root: @project_root, llvm_prefix: "/opt/llvm")

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
    1 * Kernel.exec(has_entries("RUBYLIB" => anything), "shadowenv", "exec", "--dir", @project_root.to_s, "--", "sh", "-c", "./bin/console")

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
    1 * Kernel.exec(has_entries("RUBYLIB" => anything), "shadowenv", "exec", "--dir", @project_root.to_s, "--", "sh", "-c", "./bin/console --verbose")

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
    1 * Kernel.exec(has_entries("RUBYLIB" => anything), "shadowenv", "exec", "--dir", @project_root.to_s, "--", "sh", "-c", includes("./bin/setup.rb"))

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "non-repl shell wrapper includes status check and Done message" do
    Given "a non-repl command"
    cmd = command("./bin/test.sh", repl: false)

    When "we run the command"
    @runner.exec_into(cmd)

    Then "the shell wrapper includes exit code handling and Done/Failed output"
    _ * @ui.print_header
    1 * Kernel.exec(has_entries("RUBYLIB" => anything), "shadowenv", "exec", "--dir", @project_root.to_s, "--", "sh", "-c",
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
    1 * Kernel.exec(has_entries("RUBYLIB" => anything), "shadowenv", "exec", "--dir", @project_root.to_s, "--", "sh", "-c", includes("./bin/test.sh -v"))

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
    _ * @ui.print_header
    1 * Kernel.system(has_entries("RUBYLIB" => anything), "shadowenv", "exec", "--dir", @project_root.to_s, "--", "sh", "-c", includes("./bin/setup.rb")) >> true
    0 * Kernel.exec(any_parameters)

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "run_waiting raises CommandFailedError carrying the child's exit status" do
    Given "a child that exits 7"
    cmd = command("./bin/setup.rb", repl: false)
    # Kernel.system is stubbed, so wait on a real child here to leave the
    # thread-local $? at exit status 7 — what a real failed child would set.
    Process.wait(Process.spawn("sh", "-c", "exit 7"))

    When "we run the command waiting"
    @runner.run_waiting(cmd)

    Then "the error carries the child's exit status"
    _ * @ui.print_header
    _ * Kernel.system >> false
    error = raises Dev::Cli::CommandRunner::CommandFailedError
    error.exit_status == 7

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "run_waiting raises CommandKilledError carrying the terminating signal" do
    Given "a child killed by SIGTERM"
    cmd = command("./bin/setup.rb", repl: false)
    # Kernel.system is stubbed, so wait on a real signal-killed child here to
    # leave the thread-local $? signaled — what a real killed child would set.
    Process.wait(Process.spawn("sh", "-c", "kill -TERM $$"))

    When "we run the command waiting"
    @runner.run_waiting(cmd)

    Then "the error carries the terminating signal number"
    _ * @ui.print_header
    _ * Kernel.system >> false
    error = raises Dev::Cli::CommandRunner::CommandKilledError
    error.signal == Signal.list.fetch("TERM")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "run_waiting raises CommandSpawnError when the child never started" do
    Given "a child that cannot be spawned"
    cmd = command("./bin/setup.rb", repl: false)

    When "we run the command waiting"
    @runner.run_waiting(cmd)

    Then "Kernel.system answers nil (not false) when the child never started"
    _ * @ui.print_header
    _ * Kernel.system >> nil
    raises Dev::Cli::CommandRunner::CommandSpawnError

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "run_waiting runs the containerized command spawn-and-wait: the container's status comes back, the process stays" do
    Given "a runner over a lock pinning one image"
    lock_images("myapp-linux")
    engine = FakeContainerEngine.new
    runner, client = container_runner(engine:)
    cmd = command("./bin/up.sh", repl: false)

    When "the image resolves and we run the command waiting"
    runner.run_waiting(cmd)

    Then "the engine ran it as a waited child; nothing exec'd, nothing exited"
    _ * @ui.print_header
    _ * @ui.print_remote_crossing
    _ * client.ensure_environment_image! >> "ghcr.io/d3mlabs/myapp-linux:deadbeef"
    _ * client.docker_run_command >> invocation("run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/up.sh")
    engine.runs.last == ["run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/up.sh"]
    0 * Kernel.exec(any_parameters)
    0 * Kernel.exit(any_parameters)

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "run_waiting raises CommandFailedError with the container's status when the command inside fails" do
    Given "a lock pinning one image and an engine whose run exits 5"
    lock_images("myapp-linux")
    engine = FakeContainerEngine.new(&->(args) { args.fetch(0) == "run" ? 5 : true })
    runner, client = container_runner(engine:)

    When
    runner.run_waiting(command("./bin/up.sh", repl: false))

    Then
    _ * @ui.print_header
    _ * @ui.print_remote_crossing
    _ * client.ensure_environment_image! >> "ghcr.io/d3mlabs/myapp-linux:deadbeef"
    _ * client.docker_run_command >> invocation("run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/up.sh")
    error = raises Dev::Cli::CommandRunner::CommandFailedError
    error.exit_status == 5

    Cleanup
    Dir.chdir(@original_cwd)
  end

  # --- Container execution ---
  #
  # A command in a container crosses through the container's transport
  # (Transport::LocalContainer), which delivers the tree as a workspace —
  # the checkout, bind-mounted at its own path: the container runs the
  # shell command there, and the container's exit status becomes the
  # process's own — Kernel.exit in exec mode, where a host command would
  # have exec-replaced the process.

  test "run resolves a pinned image through ensure_environment_image! and runs in it over the mounted checkout: the one image, no key needed" do
    Given "a lock pinning one image"
    lock_images("myapp-linux")
    engine = FakeContainerEngine.new
    runner, client = container_runner(engine:)
    cmd = command("./bin/build.sh", repl: false)

    When
    runner.exec_into(cmd)

    Then "the engine ran the invocation in the checkout, and the status was exited with"
    _ * @ui.print_header
    _ * @ui.print_remote_crossing
    1 * client.ensure_environment_image!(responds_with(:name, "myapp-linux"), publish: false) >> "ghcr.io/d3mlabs/myapp-linux:deadbeef"
    1 * client.docker_run_command("ghcr.io/d3mlabs/myapp-linux:deadbeef", project_root: @project_root, argv: runs_inside("./bin/build.sh"), volumes: [], env: {}) >>
      invocation("run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/build.sh")
    exit = raises SystemExit
    exit.status == 0
    engine.runs.last == ["run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/build.sh"]
    0 * Kernel.exec(any_parameters)

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "the command's args ride the shell command the container runs" do
    Given "a lock pinning one image"
    lock_images("myapp-linux")
    runner, client = container_runner

    When
    runner.exec_into(command("./bin/build.sh", repl: false), args: ["--fast"])

    Then "the argv handed to the client is sh -c and the command with its args"
    _ * @ui.print_header
    _ * @ui.print_remote_crossing
    _ * client.ensure_environment_image! >> "ghcr.io/d3mlabs/myapp-linux:deadbeef"
    1 * client.docker_run_command(anything, has_entries(argv: runs_inside("./bin/build.sh --fast"))) >>
      invocation("run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "x")
    raises SystemExit

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "a command inside that exits nonzero in exec mode exits the process with that status" do
    Given "a lock pinning one image and an engine whose run exits 9"
    lock_images("myapp-linux")
    engine = FakeContainerEngine.new(&->(args) { args.fetch(0) == "run" ? 9 : true })
    runner, client = container_runner(engine:)

    When
    runner.exec_into(command("./bin/build.sh", repl: false))

    Then
    _ * @ui.print_header
    _ * @ui.print_remote_crossing
    _ * client.ensure_environment_image! >> "ghcr.io/d3mlabs/myapp-linux:deadbeef"
    _ * client.docker_run_command >> invocation("run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/build.sh")
    exit = raises SystemExit
    exit.status == 9
    0 * Kernel.exec(any_parameters)

    Cleanup
    Dir.chdir(@original_cwd)
  end

  # --- The engine-floor gate (dev#400) ---
  #
  # No provisioner runs on this path, so the container path owns the gate:
  # one `docker info`, live, before the image is reached for — and none
  # inside the image step. The spawn shape is pinned so a second read
  # cannot creep back into BuildContainer.

  test "a containerized command measures the engine against the project's floor once, before the image is reached for" do
    Given "a lock pinning one image, a 12/24 engine, and a hint it meets"
    lock_images("myapp-linux")
    engine = engine_sized(cpus: 12, memory_gib: 24)
    runner, client = container_runner(engine:, engine_hint: Dev::EngineResources::Hint.new(cpus: 8, memory_gib: 16))

    When "the command runs"
    runner.exec_into(command("./bin/build.sh", repl: false))

    Then "one docker info, then the image's inspect, then the run — nothing measured twice"
    _ * @ui.print_header
    _ * @ui.print_remote_crossing
    _ * client.docker_run_command >> invocation("run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/build.sh")
    exit = raises SystemExit
    exit.status == 0
    engine.captures == [DOCKER_INFO]
    engine.runs.map(&:first) == ["image", "run"]

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "a containerized command on an undersized engine is refused before any image work" do
    Given "a lock pinning one image, a 4/8 engine, and a 12/24 floor, with the machine's own escape hatch out of the way"
    saved_mode = ENV.delete("DEV_ENGINE_RESOURCES")
    lock_images("myapp-linux")
    engine = engine_sized(cpus: 4, memory_gib: 8)
    runner, client = container_runner(engine:, engine_hint: Dev::EngineResources::Hint.new(cpus: 12, memory_gib: 24))

    When "the command runs"
    runner.exec_into(command("./bin/build.sh", repl: false))

    Then "the gate's verdict is the run's verdict, and the image was never inspected, pulled or built"
    _ * @ui.print_header
    _ * @ui.print_remote_crossing
    0 * client.docker_run_command
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
    runner, client = container_runner(engine:, engine_hint: nil)

    When "the command runs"
    runner.exec_into(command("./bin/build.sh", repl: false))

    Then
    _ * @ui.print_header
    _ * @ui.print_remote_crossing
    _ * client.docker_run_command >> invocation("run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/build.sh")
    exit = raises SystemExit
    exit.status == 0
    engine.captures.empty?
    engine.runs.last == ["run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/build.sh"]

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "a host command never measures the engine: no container is reached for" do
    Given "two pinned images, a floor, and a command placed on the host"
    lock_images("snappy-linux", "snappy-server")
    engine = FakeContainerEngine.new(kind: :docker, capture_result: ->(_args) { raise "docker info was called" })
    runner, client = container_runner(engine:, engine_hint: Dev::EngineResources::Hint.new(cpus: 12))

    When
    runner.exec_into(command("./bin/editor.sh", repl: false, environment: "host"))

    Then
    _ * @ui.print_header
    0 * client.ensure_environment_image!
    engine.captures.empty?
    1 * Kernel.exec(has_entries("RUBYLIB" => anything), "shadowenv", "exec", "--dir", @project_root.to_s, "--", "sh", "-c", includes("./bin/editor.sh"))

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "environment: picks the image among several, and the block's shape rides it: persist, volumes, run_env" do
    Given "two pinned images; the command names the persisted one"
    lock_images("snappy-linux", "snappy-server", persist: true, volumes: ["/e:/ue"], run_env: { "WWISE_TOKEN" => "wwise/token" })
    ENV["WWISE_TOKEN"] = "tok-123"
    engine = FakeContainerEngine.new
    runner, client = container_runner(engine:)
    cmd = command("./bin/test-server.sh", repl: false, environment: "snappy-server")

    When
    runner.exec_into(cmd)

    Then
    _ * @ui.print_header
    _ * @ui.print_remote_crossing
    1 * client.ensure_environment_image!(responds_with(:name, "snappy-server"), anything) >> "ghcr.io/d3mlabs/snappy-server:deadbeef"
    1 * client.ensure_service!("ghcr.io/d3mlabs/snappy-server:deadbeef", project_root: @project_root, volumes: ["/e:/ue"]) >> "dev-snappy-server-deadbeef"
    1 * client.docker_exec_command("dev-snappy-server-deadbeef", project_root: @project_root, argv: runs_inside("./bin/test-server.sh"), env: { "WWISE_TOKEN" => "tok-123" }) >>
      invocation("exec", "dev-snappy-server-deadbeef", "sh", "-c", "./bin/test-server.sh")
    0 * client.docker_run_command
    exit = raises SystemExit
    exit.status == 0
    engine.runs.last == ["exec", "dev-snappy-server-deadbeef", "sh", "-c", "./bin/test-server.sh"]

    Cleanup
    ENV.delete("WWISE_TOKEN")
    Dir.chdir(@original_cwd)
  end

  test "environment: host runs on this host whatever the lock pins" do
    Given "two pinned images and a command placed on the host"
    lock_images("snappy-linux", "snappy-server")
    runner, client = container_runner
    cmd = command("./bin/editor.sh", repl: false, environment: "host")

    When
    runner.exec_into(cmd)

    Then
    _ * @ui.print_header
    0 * client.ensure_environment_image!
    1 * Kernel.exec(has_entries("RUBYLIB" => anything), "shadowenv", "exec", "--dir", @project_root.to_s, "--", "sh", "-c", includes("./bin/editor.sh"))

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "a command the composition root left unbound is refused before anything runs: the runner never resolves a name" do
    Given "a pinned image and a command straight from the parser"
    lock_images("snappy-linux")
    runner, client = container_runner

    When
    runner.exec_into(Dev::Cli::ProjectCommand.new(run: "./bin/build.sh", repl: false))

    Then
    _ * @ui.print_header
    0 * client.ensure_environment_image!
    0 * Kernel.exec
    error = raises(Dev::Cli::ProjectCommand::UnboundPlacementError)
    error.message.include?("dev deps update")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "one dim crossing line is printed when a command enters a container — its destination and the workspace delivered — and none on a host or native run" do
    Given "two images; a host provisioned from one; a command on each, and one on the host"
    lock_images("snappy-linux", "snappy-server")
    server = images.named("snappy-server")
    runner, client = container_runner(marker: provisioned_from(server))

    # The container run goes last: it exits the process (SystemExit), where
    # the native and host runs exec and return under the stub.
    When
    runner.exec_into(command("./bin/server.sh", environment: "snappy-server"))
    runner.exec_into(command("./bin/editor.sh", environment: "host"))
    runner.exec_into(command("./bin/build.sh", environment: "snappy-linux"))

    Then "the crossing into snappy-linux's container is the one line"
    _ * @ui.print_header
    _ * client.ensure_environment_image! >> "ref-linux"
    _ * client.docker_run_command >> invocation("run", "--rm", "ref-linux", "sh", "-c", "./bin/build.sh")
    _ * Kernel.exec
    raises SystemExit
    1 * @ui.print_remote_crossing(destination: "in snappy-linux (container)", workspace: "the checkout, mounted")
    0 * @ui.print_remote_crossing(destination: includes("snappy-server"), workspace: anything)
    0 * @ui.print_remote_crossing(destination: includes("host"), workspace: anything)

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "the host rule is asked of the command's image: a host provisioned from one image runs that command here, the other's in a container" do
    Given "two linux/amd64 images, on a host whose marker is one of them"
    lock_images("snappy-linux", "snappy-server")
    pins = images.pinned
    server = pins.find { |image| image.name == "snappy-server" }
    engine = FakeContainerEngine.new
    runner, client = container_runner(engine:, marker: provisioned_from(server))

    When "one command runs on each"
    runner.exec_into(command("./bin/server.sh", repl: false, environment: "snappy-server"))
    runner.exec_into(command("./bin/build.sh", repl: false, environment: "snappy-linux"))

    Then "the server command execs under the host's shadowenv; the linux one in the engine, though the host is its platform too"
    _ * @ui.print_header
    _ * @ui.print_remote_crossing
    1 * client.ensure_environment_image!(responds_with(:name, "snappy-linux"), anything) >> "ref-linux"
    1 * client.docker_run_command >> invocation("run", "--rm", "ref-linux", "sh", "-c", "./bin/build.sh")
    1 * Kernel.exec(has_entries("RUBYLIB" => anything), "shadowenv", "exec", "--dir", @project_root.to_s, "--", "sh", "-c", includes("./bin/server.sh"))
    exit = raises SystemExit
    exit.status == 0
    engine.runs == [["run", "--rm", "ref-linux", "sh", "-c", "./bin/build.sh"]]

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "a host provisioned from nothing is never native: no marker, the container" do
    Given "a linux/amd64 image on a host with no marker"
    lock_images("snappy-linux")
    engine = FakeContainerEngine.new
    runner, client = container_runner(engine:)

    When
    runner.exec_into(command("./bin/build.sh", repl: false))

    Then
    _ * @ui.print_header
    _ * @ui.print_remote_crossing
    1 * client.ensure_environment_image! >> "ref-linux"
    1 * client.docker_run_command >> invocation("run", "--rm", "ref-linux", "sh", "-c", "./bin/build.sh")
    exit = raises SystemExit
    exit.status == 0
    engine.runs == [["run", "--rm", "ref-linux", "sh", "-c", "./bin/build.sh"]]

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
    engine = FakeContainerEngine.new
    runner, client = container_runner(engine:, marker: provisioned_from(older))

    When
    runner.exec_into(command("./bin/build.sh", repl: false))

    Then
    _ * @ui.print_header
    _ * @ui.print_remote_crossing
    1 * client.ensure_environment_image! >> "ref-linux"
    1 * client.docker_run_command >> invocation("run", "--rm", "ref-linux", "sh", "-c", "./bin/build.sh")
    exit = raises SystemExit
    exit.status == 0
    engine.runs == [["run", "--rm", "ref-linux", "sh", "-c", "./bin/build.sh"]]

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "inside a container of the lock's image, the image's command runs directly" do
    Given
    lock_images("snappy-linux")
    runner, client = container_runner(inside_container: true, marker: provisioned_from(images.pinned.first))

    When
    runner.exec_into(command("./bin/build.sh", repl: false))

    Then
    _ * @ui.print_header
    0 * client.docker_run_command
    1 * Kernel.exec(has_entries("RUBYLIB" => anything), "shadowenv", "exec", "--dir", @project_root.to_s, "--", "sh", "-c", includes("./bin/build.sh"))

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

    When
    runner.exec_into(command("./bin/build.sh", repl: false))

    Then
    _ * @ui.print_header
    0 * client.docker_run_command
    0 * Kernel.exec
    error = raises Dev::Cli::HostRule::ContainerDriftError
    error.message.include?("this container is snappy-linux@#{older.short_digest}")
    error.message.include?("the lock's snappy-linux is snappy-linux@#{current.short_digest}")
    error.message.include?("dev container reset && dev up")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "inside the container, a repl command execs bare under shadowenv, and the host-only LLVM is not provisioned" do
    Given "an inside runner and a repl command"
    runner = Dev::Cli::CommandRunner.new(ui: @ui, project_root: @project_root, host_rule: host_rule(inside_container: true))
    cmd = command("./bin/console", repl: true)

    When "we run the command"
    runner.exec_into(cmd)

    Then "the argv is shadowenv exec, sh -c and the command alone; llvm is the image's concern"
    _ * @ui.print_header
    0 * Dev::ShadowenvLlvm.setup!(project_root: anything, llvm_prefix: anything)
    1 * Kernel.exec(has_entries("RUBYLIB" => anything), "shadowenv", "exec", "--dir", @project_root.to_s, "--", "sh", "-c", "./bin/console")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "run falls back to local execution when the lock pins no image" do
    Given "a runner over a project pinning no image"
    runner = Dev::Cli::CommandRunner.new(ui: @ui, project_root: @project_root, llvm: no_llvm_host)
    cmd = command("./bin/build.sh", repl: false)

    When "we run the command"
    runner.exec_into(cmd)

    Then "exec uses shadowenv"
    _ * @ui.print_header
    1 * Kernel.exec(has_entries("RUBYLIB" => anything), "shadowenv", "exec", "--dir", @project_root.to_s, "--", "sh", "-c", includes("./bin/build.sh"))

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "container execution includes args in the command the workspace program becomes" do
    Given "a pinned image and a command with args"
    lock_images("myapp-linux")
    runner, client = container_runner
    cmd = command("./bin/test.sh", repl: false)

    When "we run with args"
    runner.exec_into(cmd, args: ["--verbose"])

    Then "the header names the args too, and the client is handed the command with them"
    1 * @ui.print_header("./bin/test.sh --verbose")
    _ * @ui.print_remote_crossing
    _ * client.ensure_environment_image! >> "ghcr.io/d3mlabs/myapp-linux:deadbeef"
    1 * client.docker_run_command("ghcr.io/d3mlabs/myapp-linux:deadbeef", project_root: @project_root, argv: runs_inside("./bin/test.sh --verbose"), volumes: [], env: {}) >>
      invocation("run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/test.sh --verbose")
    raises SystemExit

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "container execution injects run_env from ENV override" do
    Given "a pinned image declaring run_env and the ENV var set"
    lock_images("myapp-linux", run_env: { "WWISE_TOKEN" => "wwise/token" })
    engine = FakeContainerEngine.new
    runner, client = container_runner(engine:)
    cmd = command("./bin/build.sh", repl: false)
    ENV["WWISE_TOKEN"] = "tok-123"

    When "the command runs"
    runner.exec_into(cmd)

    Then "the argv names the variable; its value reaches the engine through the spawn env, never argv (dev#317)"
    _ * @ui.print_header
    _ * @ui.print_remote_crossing
    _ * client.ensure_environment_image! >> "ghcr.io/d3mlabs/myapp-linux:deadbeef"
    1 * client.docker_run_command("ghcr.io/d3mlabs/myapp-linux:deadbeef", project_root: @project_root, argv: runs_inside("./bin/build.sh"), volumes: [], env: { "WWISE_TOKEN" => "tok-123" }) >>
      invocation("run", "--rm", "-e", "WWISE_TOKEN", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/build.sh", env: { "WWISE_TOKEN" => "tok-123" })
    raises SystemExit
    engine.runs.last == ["run", "--rm", "-e", "WWISE_TOKEN", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/build.sh"]
    engine.run_envs.last == { "WWISE_TOKEN" => "tok-123" }

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
    runner.exec_into(cmd)

    Then "ensure_environment_image! is asked to publish the resolved image"
    _ * @ui.print_header
    _ * @ui.print_remote_crossing
    1 * client.ensure_environment_image!(responds_with(:name, "myapp-linux"), publish: true) >> "ghcr.io/d3mlabs/myapp-linux:deadbeef"
    _ * client.docker_run_command >> invocation("run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/build.sh")
    exit = raises SystemExit
    exit.status == 0

    Cleanup
    ENV.delete("DEV_PUBLISH_IMAGE")
    Dir.chdir(@original_cwd)
  end

  test "a command run inside carries the host's gh token as GH_TOKEN, after the run_env" do
    Given "a host whose gh is logged in, and a pinned image with a run_env"
    lock_images("myapp-linux", run_env: { "WWISE_TOKEN" => "wwise/token" })
    engine = FakeContainerEngine.new
    runner, client = container_runner(engine:, github_token: host_github_token("gho_host"))
    cmd = command("./bin/ue/starter/publish.sh", repl: false)
    ENV["WWISE_TOKEN"] = "tok-123"

    When "the command runs"
    runner.exec_into(cmd)

    Then "the run names both on argv; both values ride the spawn env, the token on no argv (dev#317)"
    _ * @ui.print_header
    _ * @ui.print_remote_crossing
    _ * client.ensure_environment_image! >> "ghcr.io/d3mlabs/myapp-linux:deadbeef"
    1 * client.docker_run_command("ghcr.io/d3mlabs/myapp-linux:deadbeef", project_root: @project_root, argv: runs_inside("./bin/ue/starter/publish.sh"),
      volumes: [], env: { "WWISE_TOKEN" => "tok-123", "GH_TOKEN" => "gho_host" }) >>
      invocation("run", "--rm", "-e", "WWISE_TOKEN", "-e", "GH_TOKEN", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/ue/starter/publish.sh",
        env: { "WWISE_TOKEN" => "tok-123", "GH_TOKEN" => "gho_host" })
    raises SystemExit
    engine.runs.last == ["run", "--rm", "-e", "WWISE_TOKEN", "-e", "GH_TOKEN", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/ue/starter/publish.sh"]
    engine.run_envs.last == { "WWISE_TOKEN" => "tok-123", "GH_TOKEN" => "gho_host" }

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
    runner.exec_into(cmd)

    Then "the run_env's token is the one injected"
    _ * @ui.print_header
    _ * @ui.print_remote_crossing
    _ * client.ensure_environment_image! >> "ghcr.io/d3mlabs/myapp-linux:deadbeef"
    1 * client.docker_run_command("ghcr.io/d3mlabs/myapp-linux:deadbeef", project_root: @project_root, argv: runs_inside("./bin/build.sh"),
      volumes: [], env: { "GH_TOKEN" => "gho_mine" }) >>
      invocation("run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/build.sh")
    exit = raises SystemExit
    exit.status == 0

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
    runner.exec_into(cmd)

    Then "the store is asked once and has nothing; no env is injected and the command still runs"
    1 * Dev::Credentials.load("wwise", "token") >> nil
    _ * @ui.print_header
    _ * @ui.print_remote_crossing
    _ * client.ensure_environment_image! >> "ghcr.io/d3mlabs/myapp-linux:deadbeef"
    1 * client.docker_run_command("ghcr.io/d3mlabs/myapp-linux:deadbeef", project_root: @project_root, argv: runs_inside("./bin/build.sh"), volumes: [], env: {}) >>
      invocation("run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/build.sh")
    exit = raises SystemExit
    exit.status == 0

    Cleanup
    Dir.chdir(@original_cwd)
  end
end

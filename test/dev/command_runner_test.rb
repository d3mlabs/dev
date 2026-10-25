# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/command_runner"
require "dev/build_container_config"
require "dev/credentials"
require "dev/build_container"
require "dev/engine_resources"
require "dev/shadowenv_llvm"
require "dev/shadowenv_python"
require "dev/shadowenv_ruby"
require "dev/deps/dependency"
require "dev/deps/lockfile"
require "dev/environment_image"
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
    # CommandRunner#run chdirs into @project_root, which teardown deletes.
    # Each test restores @original_cwd in its Cleanup block so later tests
    # don't run from a deleted directory (getcwd would raise ENOENT).
    @original_cwd = Dir.pwd
    @project_root = Pathname(Dir.mktmpdir("dev-runner-test"))
    @runner = Dev::CommandRunner.new(ui: @ui, project_root: @project_root)
    @runner.stubs(:ensure_shadowenv_provisioned!)
  end

  def teardown
    FileUtils.rm_rf(@project_root) if @project_root&.exist?
  end

  # A containerized runner with its engine-injected BuildContainer client
  # injected, so tests stub the client instance instead of class methods.
  # `config` is the legacy block (its keys recorded as the loader would);
  # nil is a project on the lock's pins alone.
  #
  # host_platform defaults to one no Dockerfile in these tests declares, so
  # the legacy container path is taken on every CI host (a linux-amd64
  # runner *is* a linux/amd64 environment and would run on the host). The
  # marker is the host rule's fact for pinned images: absent unless a test
  # writes one (`marker:` a path under the project root).
  def container_runner(config, host_platform: "darwin-arm64", engine: nil, inside_container: false, marker: nil)
    client = Dev::BuildContainer.new(engine: FakeContainerEngine.new)
    runner = Dev::CommandRunner.new(
      ui: @ui, images: images(config, engine:), project_root: @project_root, container_client: client,
      host_rule: host_rule(host_platform:, marker:), inside_container:,
    )
    [runner, client]
  end

  def host_rule(host_platform: "darwin-arm64", marker: nil)
    path = marker || (@project_root / "no-marker").to_s
    Dev::HostRule.new(host_environment: Dev::HostEnvironment.new(path: path), host_platform: host_platform)
  end

  # Write the marker a host provisioned from +image+ carries; returns its path.
  def provisioned_from(image)
    path = @project_root / "etc-dev-environment"
    path.write(image.marker)
    path.to_s
  end

  def images(config, engine: nil)
    Dev::ProjectImages.new(
      root: @project_root, build_container: config, legacy_keys: config ? ["build.container"] : [], engine: engine,
    )
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

  # --- Toolchain provisioning ---

  test "run provisions nothing for the interpreters: Ruby and Python are dependencies dev deps install activated" do
    Given "a runner whose provisioning step is not stubbed, on a host that needs no LLVM"
    runner = Dev::CommandRunner.new(ui: @ui, project_root: @project_root)
    Dev::ShadowenvLlvm.stubs(:ci_or_linux?).returns(true)
    Kernel.stubs(:exec)
    cmd = Dev::ProjectCommand.new(run: "./bin/console", repl: true)

    When "we run a command"
    runner.exec_into(cmd)

    Then "no interpreter is resolved, built or activated on the way to the exec"
    0 * Dev::ShadowenvRuby.activate!(keg: anything, version: anything, project_root: anything)
    0 * Dev::ShadowenvPython.activate!(keg: anything, version: anything, project_root: anything)
    1 * Kernel.exec(has_entries("GEM_HOME" => nil, "RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", "./bin/console")

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
    cmd = Dev::ProjectCommand.new(run: "./bin/console", repl: true)

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
    cmd = Dev::ProjectCommand.new(run: "./bin/console", repl: true)

    When "we run the command"
    @runner.exec_into(cmd)

    Then "header is printed and process is replaced via exec"
    1 * @ui.print_header("./bin/console")
    1 * Kernel.exec(has_entries("GEM_HOME" => nil, "RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", "./bin/console")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "run prints header and execs with args when repl" do
    Given "a repl command with args"
    cmd = Dev::ProjectCommand.new(run: "./bin/console", repl: true)

    When "we run the command with extra args"
    @runner.exec_into(cmd, args: ["--verbose"])

    Then "header includes args and exec passes them through"
    1 * @ui.print_header("./bin/console --verbose")
    1 * Kernel.exec(has_entries("GEM_HOME" => nil, "RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", "./bin/console --verbose")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "run prints header and execs with shell wrapper for non-repl" do
    Given "a non-repl command"
    cmd = Dev::ProjectCommand.new(run: "./bin/setup.rb", repl: false)

    When "we run the command"
    @runner.exec_into(cmd)

    Then "header is printed and exec is called with a shell wrapper"
    1 * @ui.print_header("./bin/setup.rb")
    1 * Kernel.exec(has_entries("GEM_HOME" => nil, "RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", includes("./bin/setup.rb"))

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "non-repl shell wrapper includes status check and Done message" do
    Given "a non-repl command"
    cmd = Dev::ProjectCommand.new(run: "./bin/test.sh", repl: false)

    When "we run the command"
    @runner.exec_into(cmd)

    Then "the shell wrapper includes exit code handling and Done/Failed output"
    1 * Kernel.exec(has_entries("GEM_HOME" => nil, "RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c",
      all_of(includes("./bin/test.sh"), includes("__dev_status=$?"), includes("Done"), includes("Failed")))

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "non-repl shell wrapper includes args" do
    Given "a non-repl command with args"
    cmd = Dev::ProjectCommand.new(run: "./bin/test.sh", repl: false)

    When "we run with args"
    @runner.exec_into(cmd, args: ["-v"])

    Then "header and wrapper both include args"
    1 * @ui.print_header("./bin/test.sh -v")
    1 * Kernel.exec(has_entries("GEM_HOME" => nil, "RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", includes("./bin/test.sh -v"))

    Cleanup
    Dir.chdir(@original_cwd)
  end

  # --- run_waiting (spawn-and-wait for callers with post-execute steps) ---

  test "run_waiting spawns and waits instead of exec-replacing the process" do
    Given "a non-repl command"
    cmd = Dev::ProjectCommand.new(run: "./bin/setup.rb", repl: false)

    When "we run the command waiting"
    @runner.run_waiting(cmd)

    Then "the command runs as a waited child, never via exec"
    1 * Kernel.system(has_entries("GEM_HOME" => nil, "RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", includes("./bin/setup.rb")) >> true
    0 * Kernel.exec(any_parameters)

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "run_waiting raises CommandFailedError carrying the child's exit status" do
    Given "a child that exits 7"
    cmd = Dev::ProjectCommand.new(run: "./bin/setup.rb", repl: false)
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
    cmd = Dev::ProjectCommand.new(run: "./bin/setup.rb", repl: false)
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
    cmd = Dev::ProjectCommand.new(run: "./bin/setup.rb", repl: false)
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
    Given "a runner with a build container"
    config = Dev::BuildContainerConfig.new(image: "myapp-linux", registry: "myregistry")
    runner, client = container_runner(config)
    cmd = Dev::ProjectCommand.new(run: "./bin/up.sh", repl: false)

    When "the image resolves and we run the command waiting"
    client.stubs(:ensure_image!).returns("myregistry/myapp-linux:content-abc123")
    client.stubs(:docker_run_command)
      .returns(["docker", "run", "--rm", "myregistry/myapp-linux:content-abc123", "sh", "-c", "./bin/up.sh"])
    runner.run_waiting(cmd)

    Then "docker runs as a waited child under the engine's env, never via exec"
    1 * Kernel.system({}, "docker", "run", "--rm", "myregistry/myapp-linux:content-abc123", "sh", "-c", "./bin/up.sh") >> true
    0 * Kernel.exec(any_parameters)

    Cleanup
    Dir.chdir(@original_cwd)
  end

  # --- Container execution ---

  test "run resolves a pinned image through ensure_environment_image! and runs in it: the one image, no key needed" do
    Given "a lock pinning one image and no container block anywhere"
    lock_images("myapp-linux")
    engine = Dev::EngineResources::Hint.new(cpus: 8)
    runner, client = container_runner(nil, engine: engine)
    cmd = Dev::ProjectCommand.new(run: "./bin/build.sh", repl: false)
    client.expects(:ensure_image!).never
    client.expects(:ensure_environment_image!).once
      .with { |image, publish:, resources:| image.name == "myapp-linux" && !publish && resources == engine }
      .returns("ghcr.io/d3mlabs/myapp-linux:deadbeef")
    client.expects(:docker_run_command)
      .with("ghcr.io/d3mlabs/myapp-linux:deadbeef", project_root: @project_root, shell_cmd: "./bin/build.sh", volumes: [], env: {})
      .returns(["docker", "run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/build.sh"])

    When
    runner.exec_into(cmd)

    Then
    1 * Kernel.exec({}, "docker", "run", "--rm", "ghcr.io/d3mlabs/myapp-linux:deadbeef", "sh", "-c", "./bin/build.sh")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "runs_on picks the image among several, and the block's shape rides it: persist, volumes, run_env" do
    Given "two pinned images; the command names the persisted one"
    lock_images("snappy-linux", "snappy-server", persist: true, volumes: ["/e:/ue"], run_env: { "WWISE_TOKEN" => "wwise/token" })
    ENV["WWISE_TOKEN"] = "tok-123"
    runner, client = container_runner(nil)
    cmd = Dev::ProjectCommand.new(run: "./bin/test-server.sh", repl: false, runs_on: "snappy-server")
    client.expects(:ensure_environment_image!).once
      .with { |image, **| image.name == "snappy-server" }
      .returns("ghcr.io/d3mlabs/snappy-server:deadbeef")
    client.expects(:ensure_service!)
      .with("ghcr.io/d3mlabs/snappy-server:deadbeef", project_root: @project_root, volumes: ["/e:/ue"])
      .returns("dev-snappy-server-deadbeef")
    client.expects(:docker_exec_command)
      .with("dev-snappy-server-deadbeef", shell_cmd: "./bin/test-server.sh", env: { "WWISE_TOKEN" => "tok-123" })
      .returns(["docker", "exec", "dev-snappy-server-deadbeef", "sh", "-c", "./bin/test-server.sh"])
    client.expects(:docker_run_command).never

    When
    runner.exec_into(cmd)

    Then
    1 * Kernel.exec({}, "docker", "exec", "dev-snappy-server-deadbeef", "sh", "-c", "./bin/test-server.sh")

    Cleanup
    ENV.delete("WWISE_TOKEN")
    Dir.chdir(@original_cwd)
  end

  test "runs_on: host runs on this host whatever the lock pins" do
    Given "two pinned images and a command placed on the host"
    lock_images("snappy-linux", "snappy-server")
    runner, client = container_runner(nil)
    runner.stubs(:ensure_shadowenv_provisioned!)
    cmd = Dev::ProjectCommand.new(run: "./bin/editor.sh", repl: false, runs_on: "host")
    client.expects(:ensure_environment_image!).never

    When
    runner.exec_into(cmd)

    Then
    1 * Kernel.exec(has_entries("GEM_HOME" => nil, "RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", includes("./bin/editor.sh"))

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "a command naming no image among several is refused before anything runs" do
    Given
    lock_images("snappy-linux", "snappy-server")
    runner, client = container_runner(nil)
    client.expects(:ensure_environment_image!).never
    Kernel.expects(:exec).never

    When
    runner.exec_into(Dev::ProjectCommand.new(run: "./bin/build.sh", repl: false))

    Then
    raises Dev::ProjectImages::AmbiguousEnvironmentImageError

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "the host rule is asked of the command's image: a host provisioned from one image runs that command here, the other's in a container" do
    Given "two linux/amd64 images, on a linux-x86_64 host whose marker is one of them"
    lock_images("snappy-linux", "snappy-server")
    images = images(nil).pinned
    server = images.find { |image| image.name == "snappy-server" }
    runner, client = container_runner(nil, host_platform: "linux-x86_64", marker: provisioned_from(server))
    runner.stubs(:ensure_llvm_provisioned!)
    client.expects(:ensure_environment_image!).once.with { |image, **| image.name == "snappy-linux" }.returns("ref-linux")
    client.expects(:docker_run_command).once.returns(["docker", "run", "--rm", "ref-linux", "sh", "-c", "./bin/build.sh"])

    When "one command runs on each"
    runner.exec_into(Dev::ProjectCommand.new(run: "./bin/server.sh", repl: false, runs_on: "snappy-server"))
    runner.exec_into(Dev::ProjectCommand.new(run: "./bin/build.sh", repl: false, runs_on: "snappy-linux"))

    Then "the server command execs under the host's shadowenv; the linux one in docker, though the host is its platform too"
    1 * Kernel.exec(has_entries("GEM_HOME" => nil, "RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", includes("./bin/server.sh"))
    1 * Kernel.exec({}, "docker", "run", "--rm", "ref-linux", "sh", "-c", "./bin/build.sh")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "a pinned image's platform alone never makes a host native: no marker, the container — on #{host}" do
    Given "a linux/amd64 image on a host of its platform, provisioned from nothing"
    lock_images("snappy-linux")
    runner, client = container_runner(nil, host_platform: host)
    client.expects(:ensure_environment_image!).once.returns("ref-linux")
    client.expects(:docker_run_command).once.returns(["docker", "run", "--rm", "ref-linux", "sh", "-c", "./bin/build.sh"])

    When
    runner.exec_into(Dev::ProjectCommand.new(run: "./bin/build.sh", repl: false))

    Then
    1 * Kernel.exec({}, "docker", "run", "--rm", "ref-linux", "sh", "-c", "./bin/build.sh")

    Cleanup
    Dir.chdir(@original_cwd)

    Where
    host           | _
    "linux-x86_64" | nil
    "darwin-arm64" | nil
  end

  test "a host provisioned from an older recipe of the image has drifted: the command runs in the lock's image" do
    Given "the marker names the image under another digest"
    lock_images("snappy-linux")
    current = images(nil).pinned.first
    older = Dev::EnvironmentImage.new(
      name: current.name, from: current.from, from_digest: current.from_digest, platform: current.platform,
      apt: ["libnss3"], registry: current.registry,
    )
    runner, client = container_runner(nil, host_platform: "linux-x86_64", marker: provisioned_from(older))
    client.expects(:ensure_environment_image!).once.returns("ref-linux")
    client.expects(:docker_run_command).once.returns(["docker", "run", "--rm", "ref-linux", "sh", "-c", "./bin/build.sh"])

    When
    runner.exec_into(Dev::ProjectCommand.new(run: "./bin/build.sh", repl: false))

    Then
    1 * Kernel.exec({}, "docker", "run", "--rm", "ref-linux", "sh", "-c", "./bin/build.sh")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "inside a container of the lock's image, the image's command runs directly" do
    Given
    lock_images("snappy-linux")
    runner, client = container_runner(nil, inside_container: true, marker: provisioned_from(images(nil).pinned.first))
    client.expects(:docker_run_command).never

    When
    runner.exec_into(Dev::ProjectCommand.new(run: "./bin/build.sh", repl: false))

    Then
    1 * Kernel.exec(has_entries("RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", includes("./bin/build.sh"))

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "inside a container that is not the lock's image, the command is refused: the container cannot replace itself" do
    Given "a container made from an older recipe"
    lock_images("snappy-linux")
    current = images(nil).pinned.first
    older = Dev::EnvironmentImage.new(
      name: current.name, from: current.from, from_digest: current.from_digest, platform: current.platform,
      apt: ["libnss3"], registry: current.registry,
    )
    runner, client = container_runner(nil, inside_container: true, marker: provisioned_from(older))
    client.expects(:docker_run_command).never
    Kernel.expects(:exec).never

    When
    error = assert_raises(Dev::HostRule::ContainerDriftError) do
      runner.exec_into(Dev::ProjectCommand.new(run: "./bin/build.sh", repl: false))
    end

    Then
    error.message.include?("this container is snappy-linux@#{older.short_digest}")
    error.message.include?("the lock's snappy-linux is snappy-linux@#{current.short_digest}")
    error.message.include?("dev container reset && dev up")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "run execs docker run when build_container is configured and command opts in" do
    Given "a runner with build_container and a command with container: true (default)"
    config = Dev::BuildContainerConfig.new(image: "myapp-linux", registry: "myregistry")
    runner, client = container_runner(config)
    cmd = Dev::ProjectCommand.new(run: "./bin/build.sh", repl: false)

    When "the client's ensure_image! returns a tag and we run the command"
    client.expects(:ensure_image!)
      .with(config, project_root: @project_root, push: false, publish: false, build_args_provider: instance_of(Proc), secrets_provider: instance_of(Proc), resources: nil)
      .returns("myregistry/myapp-linux:content-abc123")
    client.expects(:docker_run_command)
      .with("myregistry/myapp-linux:content-abc123", project_root: @project_root, shell_cmd: "./bin/build.sh", volumes: [], env: {})
      .returns(["docker", "run", "--rm", "-v", "#{@project_root}:/project", "-w", "/project", "myregistry/myapp-linux:content-abc123", "sh", "-c", "./bin/build.sh"])
    runner.exec_into(cmd)

    Then "exec is called with the engine env and the docker run command"
    1 * Kernel.exec({}, "docker", "run", "--rm", "-v", "#{@project_root}:/project", "-w", "/project", "myregistry/myapp-linux:content-abc123", "sh", "-c", "./bin/build.sh")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "run execs docker exec into the persistent container when persist is set" do
    Given "a runner whose build_container opts into persist"
    config = Dev::BuildContainerConfig.new(image: "myapp-linux", registry: "myregistry", persist: true, volumes: ["/e:/e"])
    runner, client = container_runner(config)
    cmd = Dev::ProjectCommand.new(run: "./bin/build.sh", repl: false)

    When "the image resolves and the service container is ensured"
    client.stubs(:ensure_image!).returns("myregistry/myapp-linux:content-abc123")
    client.expects(:ensure_service!)
      .with("myregistry/myapp-linux:content-abc123", project_root: @project_root, volumes: ["/e:/e"])
      .returns("dev-myapp-linux-content-abc123")
    client.expects(:docker_exec_command)
      .with("dev-myapp-linux-content-abc123", shell_cmd: "./bin/build.sh", env: {})
      .returns(["docker", "exec", "-w", "/project", "dev-myapp-linux-content-abc123", "sh", "-c", "./bin/build.sh"])
    client.expects(:docker_run_command).never
    runner.exec_into(cmd)

    Then "exec is called with the docker exec command, not docker run"
    1 * Kernel.exec({}, "docker", "exec", "-w", "/project", "dev-myapp-linux-content-abc123", "sh", "-c", "./bin/build.sh")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "run falls back to local execution when command has container: false" do
    Given "a runner with build_container but a command that opts out"
    config = Dev::BuildContainerConfig.new(image: "myapp-linux", registry: "myregistry")
    runner = Dev::CommandRunner.new(ui: @ui, images: images(config), project_root: @project_root)
    runner.stubs(:ensure_shadowenv_provisioned!)
    cmd = Dev::ProjectCommand.new(run: "./bin/deploy.sh", repl: false, container: false)

    When "we run the command"
    runner.exec_into(cmd)

    Then "exec uses shadowenv, not docker"
    1 * Kernel.exec(has_entries("GEM_HOME" => nil, "RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", includes("./bin/deploy.sh"))

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "inside the container, a containerized command runs directly: no docker, shadowenv on" do
    Given "a runner that knows it is inside, over a persist container config"
    config = Dev::BuildContainerConfig.new(image: "myapp-linux", registry: "myregistry", persist: true)
    runner, client = container_runner(config, inside_container: true)
    cmd = Dev::ProjectCommand.new(run: "./bin/build.sh", repl: false)
    client.expects(:ensure_image!).never
    client.expects(:ensure_service!).never
    client.expects(:docker_exec_command).never
    client.expects(:docker_run_command).never

    When "we run the command"
    runner.exec_into(cmd)

    Then "nothing is provisioned (LLVM is the image's), and the command execs under the project's shadowenv"
    0 * Dev::ShadowenvLlvm.setup!(project_root: anything, llvm_prefix: anything)
    1 * Kernel.exec(has_entries("GEM_HOME" => nil, "RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", includes("./bin/build.sh"))

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "on a host that is the environment, a containerized command runs directly under the host's shadowenv: #{host}" do
    Given "a persisted container config in a project whose Dockerfile declares the host's own platform"
    (@project_root / "Dockerfile").write("FROM --platform=#{docker_platform} ubuntu:22.04\n")
    config = Dev::BuildContainerConfig.new(image: "myapp-linux", registry: "myregistry", persist: true)
    runner, client = container_runner(config, host_platform: host)
    runner.stubs(:ensure_llvm_provisioned!)
    cmd = Dev::ProjectCommand.new(run: "./bin/build.sh", repl: false)
    client.expects(:ensure_image!).never
    client.expects(:ensure_service!).never
    client.expects(:docker_exec_command).never
    client.expects(:docker_run_command).never

    When "we run the command"
    runner.exec_into(cmd)

    Then "the command execs under the host's shadowenv (this is the host, not a container)"
    1 * Kernel.exec(has_entries("GEM_HOME" => nil, "RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", includes("./bin/build.sh"))

    Cleanup
    Dir.chdir(@original_cwd)

    Where
    docker_platform | host
    "linux/amd64"   | "linux-x86_64"
    "linux/arm64"   | "linux-arm64"
  end

  test "on a host of another platform, the declaration changes nothing: the command still runs in the container" do
    Given "a linux/amd64 environment on a darwin-arm64 host"
    (@project_root / "Dockerfile").write("FROM --platform=linux/amd64 ubuntu:22.04\n")
    config = Dev::BuildContainerConfig.new(image: "myapp-linux", registry: "myregistry")
    runner, client = container_runner(config, host_platform: "darwin-arm64")
    cmd = Dev::ProjectCommand.new(run: "./bin/build.sh", repl: false)
    Kernel.stubs(:exec)

    When "we run the command"
    client.expects(:ensure_image!).once.returns("myregistry/myapp-linux:content-abc123")
    client.expects(:docker_run_command).once.returns(["docker", "run", "--rm", "myregistry/myapp-linux:content-abc123", "sh", "-c", "./bin/build.sh"])
    runner.exec_into(cmd)

    Then "docker ran it"
    1 * Kernel.exec({}, "docker", "run", "--rm", "myregistry/myapp-linux:content-abc123", "sh", "-c", "./bin/build.sh")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "inside the container, a repl command execs bare under shadowenv, and the host-only LLVM is not provisioned" do
    Given "an inside runner and a repl command"
    runner = Dev::CommandRunner.new(ui: @ui, project_root: @project_root, inside_container: true)
    cmd = Dev::ProjectCommand.new(run: "./bin/console", repl: true)

    When "we run the command"
    runner.exec_into(cmd)

    Then "the argv is shadowenv exec, sh -c and the command alone; llvm is the image's concern"
    0 * Dev::ShadowenvLlvm.setup!(project_root: anything, llvm_prefix: anything)
    1 * Kernel.exec(has_entries("GEM_HOME" => nil, "RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", "./bin/console")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "run falls back to local execution when no build_container is configured" do
    Given "a runner without build_container"
    runner = Dev::CommandRunner.new(ui: @ui, project_root: @project_root)
    runner.stubs(:ensure_shadowenv_provisioned!)
    cmd = Dev::ProjectCommand.new(run: "./bin/build.sh", repl: false)

    When "we run the command"
    runner.exec_into(cmd)

    Then "exec uses shadowenv"
    1 * Kernel.exec(has_entries("GEM_HOME" => nil, "RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", includes("./bin/build.sh"))

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "container execution includes args in shell command" do
    Given "a runner with build_container and a command with args"
    config = Dev::BuildContainerConfig.new(image: "myapp-linux", registry: "myregistry")
    runner, client = container_runner(config)
    cmd = Dev::ProjectCommand.new(run: "./bin/test.sh", repl: false)

    When "the client returns a docker command and we run with args"
    client.expects(:ensure_image!)
      .with(config, project_root: @project_root, push: false, publish: false, build_args_provider: instance_of(Proc), secrets_provider: instance_of(Proc), resources: nil)
      .returns("myregistry/myapp-linux:content-abc123")
    client.expects(:docker_run_command)
      .with("myregistry/myapp-linux:content-abc123", project_root: @project_root, shell_cmd: "./bin/test.sh --verbose", volumes: [], env: {})
      .returns(["docker", "run", "--rm", "myregistry/myapp-linux:content-abc123", "sh", "-c", "./bin/test.sh --verbose"])
    runner.exec_into(cmd, args: ["--verbose"])

    Then "the args are included in the shell command passed to docker"
    1 * @ui.print_header("./bin/test.sh --verbose")
    1 * Kernel.exec({}, "docker", "run", "--rm", "myregistry/myapp-linux:content-abc123", "sh", "-c", "./bin/test.sh --verbose")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "container execution injects run_env from ENV override" do
    Given "a runner with build_container declaring run_env and the ENV var set"
    config = Dev::BuildContainerConfig.new(
      image: "myapp-linux", registry: "myregistry",
      run_env: { "WWISE_TOKEN" => "wwise/token" },
    )
    runner, client = container_runner(config)
    cmd = Dev::ProjectCommand.new(run: "./bin/build.sh", repl: false)
    ENV["WWISE_TOKEN"] = "tok-123"

    When "the image is ready and the command runs"
    client.stubs(:ensure_image!).returns("myregistry/myapp-linux:content-abc123")
    client.expects(:docker_run_command)
      .with("myregistry/myapp-linux:content-abc123", project_root: @project_root, shell_cmd: "./bin/build.sh", volumes: [], env: { "WWISE_TOKEN" => "tok-123" })
      .returns(["docker", "run", "--rm", "myregistry/myapp-linux:content-abc123", "sh", "-c", "./bin/build.sh"])
    runner.exec_into(cmd)

    Then "the ENV value is passed through to docker run"
    1 * Kernel.exec({}, "docker", "run", "--rm", "myregistry/myapp-linux:content-abc123", "sh", "-c", "./bin/build.sh")

    Cleanup
    ENV.delete("WWISE_TOKEN")
    Dir.chdir(@original_cwd)
  end

  test "container execution opts into publishing when DEV_PUBLISH_IMAGE is set" do
    Given "a runner with build_container and DEV_PUBLISH_IMAGE=1 in the env"
    config = Dev::BuildContainerConfig.new(image: "myapp-linux", registry: "myregistry")
    runner, client = container_runner(config)
    cmd = Dev::ProjectCommand.new(run: "./bin/build.sh", repl: false)
    ENV["DEV_PUBLISH_IMAGE"] = "1"

    When "the command runs"
    client.expects(:ensure_image!)
      .with(config, project_root: @project_root, push: false, publish: true, build_args_provider: instance_of(Proc), secrets_provider: instance_of(Proc), resources: nil)
      .returns("myregistry/myapp-linux:content-abc123")
    client.stubs(:docker_run_command).returns(["docker", "run", "--rm", "myregistry/myapp-linux:content-abc123", "sh", "-c", "./bin/build.sh"])
    runner.exec_into(cmd)

    Then "ensure_image! is asked to publish the resolved image"
    1 * Kernel.exec({}, "docker", "run", "--rm", "myregistry/myapp-linux:content-abc123", "sh", "-c", "./bin/build.sh")

    Cleanup
    ENV.delete("DEV_PUBLISH_IMAGE")
    Dir.chdir(@original_cwd)
  end

  test "container execution skips unresolvable run_env without prompting" do
    Given "a runner with run_env whose value is not in ENV or storage"
    config = Dev::BuildContainerConfig.new(
      image: "myapp-linux", registry: "myregistry",
      run_env: { "WWISE_TOKEN" => "wwise/token" },
    )
    runner, client = container_runner(config)
    cmd = Dev::ProjectCommand.new(run: "./bin/build.sh", repl: false)
    ENV.delete("WWISE_TOKEN")

    When "the credential is not stored and the command runs"
    Dev::Credentials.stubs(:load).with("wwise", "token").returns(nil)
    client.stubs(:ensure_image!).returns("myregistry/myapp-linux:content-abc123")
    client.expects(:docker_run_command)
      .with("myregistry/myapp-linux:content-abc123", project_root: @project_root, shell_cmd: "./bin/build.sh", volumes: [], env: {})
      .returns(["docker", "run", "--rm", "myregistry/myapp-linux:content-abc123", "sh", "-c", "./bin/build.sh"])
    runner.exec_into(cmd)

    Then "no env is injected and the command still runs"
    1 * Kernel.exec({}, "docker", "run", "--rm", "myregistry/myapp-linux:content-abc123", "sh", "-c", "./bin/build.sh")

    Cleanup
    Dir.chdir(@original_cwd)
  end
end

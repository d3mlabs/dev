# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/command_runner"
require "dev/build_container_config"
require "dev/credentials"
require "dev/build_container"
require "dev/shadowenv_ruby"

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
    @runner = Dev::CommandRunner.new(ui: @ui, ruby_version: "4.0.1", project_root: @project_root)
    @runner.stubs(:ensure_shadowenv_provisioned!)
  end

  def teardown
    FileUtils.rm_rf(@project_root) if @project_root&.exist?
  end

  # --- Toolchain provisioning ---

  test "run routes Ruby provisioning through the shared guarded ensure!" do
    Given "a runner whose provisioning step is not stubbed"
    runner = Dev::CommandRunner.new(ui: @ui, ruby_version: "4.0.1", project_root: @project_root)
    runner.stubs(:ensure_llvm_provisioned!)
    runner.stubs(:ensure_python_provisioned!)
    Kernel.stubs(:exec)
    cmd = Dev::ProjectCommand.new(run: "./bin/console", repl: true)

    When "we run a command"
    runner.exec_into(cmd)

    Then "the declared Ruby is ensured for the project root"
    1 * Dev::ShadowenvRuby.ensure!(ruby_version: "4.0.1", project_root: @project_root)

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
    runner = Dev::CommandRunner.new(ui: @ui, ruby_version: "4.0.1", build_container: config, project_root: @project_root)
    cmd = Dev::ProjectCommand.new(run: "./bin/up.sh", repl: false)

    When "the image resolves and we run the command waiting"
    Dev::BuildContainer.stubs(:ensure_image!).returns("myregistry/myapp-linux:content-abc123")
    Dev::BuildContainer.stubs(:docker_run_command)
      .returns(["docker", "run", "--rm", "myregistry/myapp-linux:content-abc123", "sh", "-c", "./bin/up.sh"])
    runner.run_waiting(cmd)

    Then "docker runs as a waited child, never via exec"
    1 * Kernel.system("docker", "run", "--rm", "myregistry/myapp-linux:content-abc123", "sh", "-c", "./bin/up.sh") >> true
    0 * Kernel.exec(any_parameters)

    Cleanup
    Dir.chdir(@original_cwd)
  end

  # --- Container execution ---

  test "run execs docker run when build_container is configured and command opts in" do
    Given "a runner with build_container and a command with container: true (default)"
    config = Dev::BuildContainerConfig.new(image: "myapp-linux", registry: "myregistry")
    runner = Dev::CommandRunner.new(ui: @ui, ruby_version: "4.0.1", build_container: config, project_root: @project_root)
    cmd = Dev::ProjectCommand.new(run: "./bin/build.sh", repl: false)

    When "Dev::BuildContainer.ensure_image! returns a tag and we run the command"
    Dev::BuildContainer.expects(:ensure_image!)
      .with(config, project_root: @project_root, push: false, publish: false, build_args_provider: instance_of(Proc), secrets_provider: instance_of(Proc))
      .returns("myregistry/myapp-linux:content-abc123")
    Dev::BuildContainer.expects(:docker_run_command)
      .with("myregistry/myapp-linux:content-abc123", project_root: @project_root, shell_cmd: "./bin/build.sh", volumes: [], env: {})
      .returns(["docker", "run", "--rm", "-v", "#{@project_root}:/project", "-w", "/project", "myregistry/myapp-linux:content-abc123", "sh", "-c", "./bin/build.sh"])
    runner.exec_into(cmd)

    Then "exec is called with the docker run command"
    1 * Kernel.exec("docker", "run", "--rm", "-v", "#{@project_root}:/project", "-w", "/project", "myregistry/myapp-linux:content-abc123", "sh", "-c", "./bin/build.sh")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "run execs docker exec into the persistent container when persist is set" do
    Given "a runner whose build_container opts into persist"
    config = Dev::BuildContainerConfig.new(image: "myapp-linux", registry: "myregistry", persist: true, volumes: ["/e:/e"])
    runner = Dev::CommandRunner.new(ui: @ui, ruby_version: "4.0.1", build_container: config, project_root: @project_root)
    cmd = Dev::ProjectCommand.new(run: "./bin/build.sh", repl: false)

    When "the image resolves and the service container is ensured"
    Dev::BuildContainer.stubs(:ensure_image!).returns("myregistry/myapp-linux:content-abc123")
    Dev::BuildContainer.expects(:ensure_service!)
      .with("myregistry/myapp-linux:content-abc123", project_root: @project_root, volumes: ["/e:/e"])
      .returns("dev-myapp-linux-content-abc123")
    Dev::BuildContainer.expects(:docker_exec_command)
      .with("dev-myapp-linux-content-abc123", shell_cmd: "./bin/build.sh", env: {})
      .returns(["docker", "exec", "-w", "/project", "dev-myapp-linux-content-abc123", "sh", "-c", "./bin/build.sh"])
    Dev::BuildContainer.expects(:docker_run_command).never
    runner.exec_into(cmd)

    Then "exec is called with the docker exec command, not docker run"
    1 * Kernel.exec("docker", "exec", "-w", "/project", "dev-myapp-linux-content-abc123", "sh", "-c", "./bin/build.sh")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "run falls back to local execution when command has container: false" do
    Given "a runner with build_container but a command that opts out"
    config = Dev::BuildContainerConfig.new(image: "myapp-linux", registry: "myregistry")
    runner = Dev::CommandRunner.new(ui: @ui, ruby_version: "4.0.1", build_container: config, project_root: @project_root)
    runner.stubs(:ensure_shadowenv_provisioned!)
    cmd = Dev::ProjectCommand.new(run: "./bin/deploy.sh", repl: false, container: false)

    When "we run the command"
    runner.exec_into(cmd)

    Then "exec uses shadowenv, not docker"
    1 * Kernel.exec(has_entries("GEM_HOME" => nil, "RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", includes("./bin/deploy.sh"))

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "run falls back to local execution when no build_container is configured" do
    Given "a runner without build_container"
    runner = Dev::CommandRunner.new(ui: @ui, ruby_version: "4.0.1", project_root: @project_root)
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
    runner = Dev::CommandRunner.new(ui: @ui, ruby_version: "4.0.1", build_container: config, project_root: @project_root)
    cmd = Dev::ProjectCommand.new(run: "./bin/test.sh", repl: false)

    When "Dev::BuildContainer returns docker command and we run with args"
    Dev::BuildContainer.expects(:ensure_image!)
      .with(config, project_root: @project_root, push: false, publish: false, build_args_provider: instance_of(Proc), secrets_provider: instance_of(Proc))
      .returns("myregistry/myapp-linux:content-abc123")
    Dev::BuildContainer.expects(:docker_run_command)
      .with("myregistry/myapp-linux:content-abc123", project_root: @project_root, shell_cmd: "./bin/test.sh --verbose", volumes: [], env: {})
      .returns(["docker", "run", "--rm", "myregistry/myapp-linux:content-abc123", "sh", "-c", "./bin/test.sh --verbose"])
    runner.exec_into(cmd, args: ["--verbose"])

    Then "the args are included in the shell command passed to docker"
    1 * @ui.print_header("./bin/test.sh --verbose")
    1 * Kernel.exec("docker", "run", "--rm", "myregistry/myapp-linux:content-abc123", "sh", "-c", "./bin/test.sh --verbose")

    Cleanup
    Dir.chdir(@original_cwd)
  end

  test "container execution injects run_env from ENV override" do
    Given "a runner with build_container declaring run_env and the ENV var set"
    config = Dev::BuildContainerConfig.new(
      image: "myapp-linux", registry: "myregistry",
      run_env: { "WWISE_TOKEN" => "wwise/token" },
    )
    runner = Dev::CommandRunner.new(ui: @ui, ruby_version: "4.0.1", build_container: config, project_root: @project_root)
    cmd = Dev::ProjectCommand.new(run: "./bin/build.sh", repl: false)
    ENV["WWISE_TOKEN"] = "tok-123"

    When "the image is ready and the command runs"
    Dev::BuildContainer.stubs(:ensure_image!).returns("myregistry/myapp-linux:content-abc123")
    Dev::BuildContainer.expects(:docker_run_command)
      .with("myregistry/myapp-linux:content-abc123", project_root: @project_root, shell_cmd: "./bin/build.sh", volumes: [], env: { "WWISE_TOKEN" => "tok-123" })
      .returns(["docker", "run", "--rm", "myregistry/myapp-linux:content-abc123", "sh", "-c", "./bin/build.sh"])
    runner.exec_into(cmd)

    Then "the ENV value is passed through to docker run"
    1 * Kernel.exec("docker", "run", "--rm", "myregistry/myapp-linux:content-abc123", "sh", "-c", "./bin/build.sh")

    Cleanup
    ENV.delete("WWISE_TOKEN")
    Dir.chdir(@original_cwd)
  end

  test "container execution opts into publishing when DEV_PUBLISH_IMAGE is set" do
    Given "a runner with build_container and DEV_PUBLISH_IMAGE=1 in the env"
    config = Dev::BuildContainerConfig.new(image: "myapp-linux", registry: "myregistry")
    runner = Dev::CommandRunner.new(ui: @ui, ruby_version: "4.0.1", build_container: config, project_root: @project_root)
    cmd = Dev::ProjectCommand.new(run: "./bin/build.sh", repl: false)
    ENV["DEV_PUBLISH_IMAGE"] = "1"

    When "the command runs"
    Dev::BuildContainer.expects(:ensure_image!)
      .with(config, project_root: @project_root, push: false, publish: true, build_args_provider: instance_of(Proc), secrets_provider: instance_of(Proc))
      .returns("myregistry/myapp-linux:content-abc123")
    Dev::BuildContainer.stubs(:docker_run_command).returns(["docker", "run", "--rm", "myregistry/myapp-linux:content-abc123", "sh", "-c", "./bin/build.sh"])
    runner.exec_into(cmd)

    Then "ensure_image! is asked to publish the resolved image"
    1 * Kernel.exec("docker", "run", "--rm", "myregistry/myapp-linux:content-abc123", "sh", "-c", "./bin/build.sh")

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
    runner = Dev::CommandRunner.new(ui: @ui, ruby_version: "4.0.1", build_container: config, project_root: @project_root)
    cmd = Dev::ProjectCommand.new(run: "./bin/build.sh", repl: false)
    ENV.delete("WWISE_TOKEN")

    When "the credential is not stored and the command runs"
    Dev::Credentials.stubs(:load).with("wwise", "token").returns(nil)
    Dev::BuildContainer.stubs(:ensure_image!).returns("myregistry/myapp-linux:content-abc123")
    Dev::BuildContainer.expects(:docker_run_command)
      .with("myregistry/myapp-linux:content-abc123", project_root: @project_root, shell_cmd: "./bin/build.sh", volumes: [], env: {})
      .returns(["docker", "run", "--rm", "myregistry/myapp-linux:content-abc123", "sh", "-c", "./bin/build.sh"])
    runner.exec_into(cmd)

    Then "no env is injected and the command still runs"
    1 * Kernel.exec("docker", "run", "--rm", "myregistry/myapp-linux:content-abc123", "sh", "-c", "./bin/build.sh")

    Cleanup
    Dir.chdir(@original_cwd)
  end
end

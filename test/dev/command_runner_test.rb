# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/command_runner"
require "dev/build_container_config"
require "build_container"

transform!(RSpock::AST::Transformation)
class CommandRunnerTest < Minitest::Test
  extend T::Sig
  include SorbetHelper

  def setup
    @ui = typed_mock(Dev::Cli::Ui)
    @ui.stubs(:print_header)
    @project_root = Pathname(Dir.mktmpdir("dev-runner-test"))
    @runner = Dev::CommandRunner.new(ui: @ui, ruby_version: "4.0.1", project_root: @project_root)
    @runner.stubs(:ensure_shadowenv_provisioned!)
  end

  def teardown
    FileUtils.rm_rf(@project_root) if @project_root&.exist?
  end

  # --- Local execution (no container) ---

  test "run prints header and execs directly when repl" do
    Given "a repl command"
    cmd = Dev::ShellCommand.new(run: "./bin/console", repl: true)

    When "we run the command"
    @runner.run(cmd)

    Then "header is printed and process is replaced via exec"
    1 * @ui.print_header("./bin/console")
    1 * Kernel.exec(has_entries("GEM_HOME" => nil, "RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", "./bin/console")
  end

  test "run prints header and execs with args when repl" do
    Given "a repl command with args"
    cmd = Dev::ShellCommand.new(run: "./bin/console", repl: true)

    When "we run the command with extra args"
    @runner.run(cmd, args: ["--verbose"])

    Then "header includes args and exec passes them through"
    1 * @ui.print_header("./bin/console --verbose")
    1 * Kernel.exec(has_entries("GEM_HOME" => nil, "RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", "./bin/console --verbose")
  end

  test "run prints header and execs with shell wrapper for non-repl" do
    Given "a non-repl command"
    cmd = Dev::ShellCommand.new(run: "./bin/setup.rb", repl: false)

    When "we run the command"
    @runner.run(cmd)

    Then "header is printed and exec is called with a shell wrapper"
    1 * @ui.print_header("./bin/setup.rb")
    1 * Kernel.exec(has_entries("GEM_HOME" => nil, "RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", includes("./bin/setup.rb"))
  end

  test "non-repl shell wrapper includes status check and Done message" do
    Given "a non-repl command"
    cmd = Dev::ShellCommand.new(run: "./bin/test.sh", repl: false)

    When "we run the command"
    @runner.run(cmd)

    Then "the shell wrapper includes exit code handling and Done/Failed output"
    1 * Kernel.exec(has_entries("GEM_HOME" => nil, "RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c",
      all_of(includes("./bin/test.sh"), includes("__dev_status=$?"), includes("Done"), includes("Failed")))
  end

  test "non-repl shell wrapper includes args" do
    Given "a non-repl command with args"
    cmd = Dev::ShellCommand.new(run: "./bin/test.sh", repl: false)

    When "we run with args"
    @runner.run(cmd, args: ["-v"])

    Then "header and wrapper both include args"
    1 * @ui.print_header("./bin/test.sh -v")
    1 * Kernel.exec(has_entries("GEM_HOME" => nil, "RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", includes("./bin/test.sh -v"))
  end

  # --- Container execution ---

  test "run execs docker run when build_container is configured and command opts in" do
    Given "a runner with build_container and a command with container: true (default)"
    config = Dev::BuildContainerConfig.new(image: "myapp-linux", registry: "myregistry")
    runner = Dev::CommandRunner.new(ui: @ui, ruby_version: "4.0.1", build_container: config, project_root: @project_root)
    cmd = Dev::ShellCommand.new(run: "./bin/build.sh", repl: false)

    When "BuildContainer.ensure_image! returns a tag and we run the command"
    BuildContainer.expects(:ensure_image!)
      .with(config, project_root: @project_root, push: false, build_args_provider: instance_of(Proc))
      .returns("myregistry/myapp-linux:content-abc123")
    BuildContainer.expects(:docker_run_command)
      .with("myregistry/myapp-linux:content-abc123", project_root: @project_root, shell_cmd: "./bin/build.sh", volumes: [])
      .returns(["docker", "run", "--rm", "-v", "#{@project_root}:/project", "-w", "/project", "myregistry/myapp-linux:content-abc123", "sh", "-c", "./bin/build.sh"])
    runner.run(cmd)

    Then "exec is called with the docker run command"
    1 * Kernel.exec("docker", "run", "--rm", "-v", "#{@project_root}:/project", "-w", "/project", "myregistry/myapp-linux:content-abc123", "sh", "-c", "./bin/build.sh")
  end

  test "run falls back to local execution when command has container: false" do
    Given "a runner with build_container but a command that opts out"
    config = Dev::BuildContainerConfig.new(image: "myapp-linux", registry: "myregistry")
    runner = Dev::CommandRunner.new(ui: @ui, ruby_version: "4.0.1", build_container: config, project_root: @project_root)
    runner.stubs(:ensure_shadowenv_provisioned!)
    cmd = Dev::ShellCommand.new(run: "./bin/deploy.sh", repl: false, container: false)

    When "we run the command"
    runner.run(cmd)

    Then "exec uses shadowenv, not docker"
    1 * Kernel.exec(has_entries("GEM_HOME" => nil, "RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", includes("./bin/deploy.sh"))
  end

  test "run falls back to local execution when no build_container is configured" do
    Given "a runner without build_container"
    runner = Dev::CommandRunner.new(ui: @ui, ruby_version: "4.0.1", project_root: @project_root)
    runner.stubs(:ensure_shadowenv_provisioned!)
    cmd = Dev::ShellCommand.new(run: "./bin/build.sh", repl: false)

    When "we run the command"
    runner.run(cmd)

    Then "exec uses shadowenv"
    1 * Kernel.exec(has_entries("GEM_HOME" => nil, "RUBYLIB" => anything), "shadowenv", "exec", "--", "sh", "-c", includes("./bin/build.sh"))
  end

  test "container execution includes args in shell command" do
    Given "a runner with build_container and a command with args"
    config = Dev::BuildContainerConfig.new(image: "myapp-linux", registry: "myregistry")
    runner = Dev::CommandRunner.new(ui: @ui, ruby_version: "4.0.1", build_container: config, project_root: @project_root)
    cmd = Dev::ShellCommand.new(run: "./bin/test.sh", repl: false)

    When "BuildContainer returns docker command and we run with args"
    BuildContainer.expects(:ensure_image!)
      .with(config, project_root: @project_root, push: false, build_args_provider: instance_of(Proc))
      .returns("myregistry/myapp-linux:content-abc123")
    BuildContainer.expects(:docker_run_command)
      .with("myregistry/myapp-linux:content-abc123", project_root: @project_root, shell_cmd: "./bin/test.sh --verbose", volumes: [])
      .returns(["docker", "run", "--rm", "myregistry/myapp-linux:content-abc123", "sh", "-c", "./bin/test.sh --verbose"])
    runner.run(cmd, args: ["--verbose"])

    Then "the args are included in the shell command passed to docker"
    1 * @ui.print_header("./bin/test.sh --verbose")
    1 * Kernel.exec("docker", "run", "--rm", "myregistry/myapp-linux:content-abc123", "sh", "-c", "./bin/test.sh --verbose")
  end
end

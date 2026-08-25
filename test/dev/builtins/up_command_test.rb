# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/install_deps_command"
require "dev/builtins/up_command"
require "dev/build_container_config"
require "dev/credentials"
require "pathname"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::UpCommandTest < Minitest::Test
  include SorbetHelper

  test "traits: staleness-exempt (it IS the remediation) and stamps on success" do
    Given "the builtin"
    command = build_command

    Expect "the declarative traits"
    command.staleness_exempt? == true
    command.stamps? == true
    !command.hidden?
  end

  test "call ensures the dev cd shell hook and composes the install-deps body" do
    Given "an up command with expectations on both collaborators"
    install_deps = typed_mock(Dev::Builtins::InstallDepsCommand)
    hook_installer = typed_mock(Dev::Cd::HookInstaller)
    hook_installer.expects(:ensure_installed).once.returns(:already_present)
    command = Dev::Builtins::UpCommand.new(
      install_deps_command: install_deps, hook_installer: hook_installer, host_converge: quiet_host_converge,
    )
    context = build_context

    When "running up"
    command.call(args: ["-v"], context: context)

    Then "the install body received the same args and context"
    1 * install_deps.call(args: ["-v"], context: context)
  end

  test "call converges the host layer as its first step" do
    Given "an up command whose host converge expects its run"
    host_converge = typed_mock(Dev::Host::Converge)
    host_converge.expects(:run).once
    install_deps = typed_mock(Dev::Builtins::InstallDepsCommand)
    install_deps.stubs(:call)
    hook_installer = typed_mock(Dev::Cd::HookInstaller)
    hook_installer.stubs(:ensure_installed).returns(:already_present)
    command = Dev::Builtins::UpCommand.new(
      install_deps_command: install_deps, hook_installer: hook_installer, host_converge: host_converge,
    )

    When "running up"
    command.call(args: [], context: build_context)

    Then "the expectation on the host converge holds"
    true
  end

  test "call without a project converges the host half and skips provisioning" do
    Given "a projectless context and collaborators expecting only host work"
    host_converge = typed_mock(Dev::Host::Converge)
    host_converge.expects(:run).once
    hook_installer = typed_mock(Dev::Cd::HookInstaller)
    hook_installer.expects(:ensure_installed).once.returns(:appended)
    install_deps = typed_mock(Dev::Builtins::InstallDepsCommand)
    command = Dev::Builtins::UpCommand.new(
      install_deps_command: install_deps, hook_installer: hook_installer, host_converge: host_converge,
    )
    context = Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui))

    When "running up outside any project"
    stdout = capture_stdout { command.call(args: [], context: context) }

    Then "install-deps and credentials never run, and the bootstrap message points at projects"
    0 * install_deps.call(args: anything, context: anything)
    0 * Dev::Credentials.resolve_build_args(anything)
    stdout.include?("dev: host layer converged.")
    stdout.include?("no dev.yml here — run dev up inside a project to provision it too")
  end

  test "call resolves docker build arg credentials before anything else" do
    Given "a context whose build container declares build_args"
    command = build_command
    context = build_context(build_container: container_config(build_args: { "WWISE_EMAIL" => "wwise/email" }))

    When "running up"
    command.call(args: [], context: context)

    Then "build args are resolved (prompting and storing on first run)"
    1 * Dev::Credentials.resolve_build_args({ "WWISE_EMAIL" => "wwise/email" })
  end

  test "call skips credential provisioning without a build container" do
    Given "a context without a build container"
    command = build_command
    context = build_context

    When "running up"
    command.call(args: [], context: context)

    Then "credentials are never resolved"
    0 * Dev::Credentials.resolve_build_args(anything)
  end

  test "call skips credential provisioning when the container declares no build_args" do
    Given "a context whose build container has no build_args"
    command = build_command
    context = build_context(build_container: container_config(build_args: {}))

    When "running up"
    command.call(args: [], context: context)

    Then "credentials are never resolved"
    0 * Dev::Credentials.resolve_build_args(anything)
  end

  private

  def build_command
    install_deps = typed_mock(Dev::Builtins::InstallDepsCommand)
    install_deps.stubs(:call)
    hook_installer = typed_mock(Dev::Cd::HookInstaller)
    hook_installer.stubs(:ensure_installed).returns(:already_present)
    Dev::Builtins::UpCommand.new(
      install_deps_command: install_deps, hook_installer: hook_installer, host_converge: quiet_host_converge,
    )
  end

  def quiet_host_converge
    host_converge = typed_mock(Dev::Host::Converge)
    host_converge.stubs(:run)
    host_converge
  end

  def container_config(build_args:)
    Dev::BuildContainerConfig.new(image: "myapp-linux", registry: "myregistry", build_args: build_args)
  end

  def capture_stdout
    old_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old_stdout
  end

  def build_context(build_container: nil)
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui),
      project: Dev::ProjectContext.new(
        root: Pathname.new("/tmp/up-test"),
        ruby_version: "4.0.1",
        build_container: build_container,
      ),
    )
  end
end

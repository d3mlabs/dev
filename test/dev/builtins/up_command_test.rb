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
    host_service = typed_mock(Dev::HostService)
    host_service.stubs(:converge_tooling)
    host_service.expects(:install_rc_hook).once.returns(:already_present)
    command = Dev::Builtins::UpCommand.new(install_deps_command: install_deps, host_service: host_service)
    context = build_context

    When "running up"
    command.call(args: ["-v"], context: context)

    Then "the install body received the same args and context"
    1 * install_deps.call(args: ["-v"], context: context)
  end

  test "call converges the host tooling as its first step" do
    Given "an up command whose host service expects the tooling converge"
    host_service = typed_mock(Dev::HostService)
    host_service.expects(:converge_tooling).once
    host_service.stubs(:install_rc_hook).returns(:already_present)
    install_deps = typed_mock(Dev::Builtins::InstallDepsCommand)
    install_deps.stubs(:call)
    command = Dev::Builtins::UpCommand.new(install_deps_command: install_deps, host_service: host_service)

    When "running up"
    command.call(args: [], context: build_context)

    Then "the expectation on the host service holds"
    true
  end

  test "call without a project converges the host half and skips provisioning" do
    Given "a projectless context and a host service expecting only host work"
    host_service = typed_mock(Dev::HostService)
    host_service.expects(:converge_tooling).once
    host_service.expects(:install_rc_hook).once.returns(:appended)
    install_deps = typed_mock(Dev::Builtins::InstallDepsCommand)
    command = Dev::Builtins::UpCommand.new(install_deps_command: install_deps, host_service: host_service)
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
    Dev::Builtins::UpCommand.new(install_deps_command: install_deps, host_service: quiet_host_service)
  end

  def quiet_host_service
    host_service = typed_mock(Dev::HostService)
    host_service.stubs(:converge_tooling)
    host_service.stubs(:install_rc_hook).returns(:already_present)
    host_service
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

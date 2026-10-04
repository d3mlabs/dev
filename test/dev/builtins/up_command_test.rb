# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/container_up_command"
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

  test "call ensures the dev cd shell hook and composes the dev deps install body" do
    Given "an up command with expectations on both collaborators"
    install_deps = typed_mock(Dev::Builtins::InstallDepsCommand)
    host_service = quiet_host_service
    host_service.expects(:install_rc_hook).once.returns(:already_present)
    command = Dev::Builtins::UpCommand.new(install_deps_command: install_deps, host_service: host_service)
    context = build_context

    When "running up"
    command.call(args: ["-v"], context: context)

    Then "the install body received the same args and context"
    1 * install_deps.call(args: ["-v"], context: context)
  end

  test "call converges the host tooling and links shipped skills as its host half" do
    Given "an up command whose host service expects the converge and the skill links"
    host_service = quiet_host_service
    host_service.expects(:converge_tooling).once
    host_service.expects(:install_skills).once
    install_deps = typed_mock(Dev::Builtins::InstallDepsCommand)
    install_deps.stubs(:call)
    command = Dev::Builtins::UpCommand.new(install_deps_command: install_deps, host_service: host_service)

    When "running up"
    command.call(args: [], context: build_context)

    Then "the expectations on the host service hold"
    true
  end

  test "call without a project converges the host half, syncs org learnings, and skips provisioning" do
    Given "a projectless context and a host service expecting only host work"
    host_service = typed_mock(Dev::HostService)
    host_service.expects(:converge_tooling).once
    host_service.expects(:install_rc_hook).once.returns(:added)
    host_service.expects(:install_skills).once
    host_service.expects(:sync_learnings).with(project_root: nil).once
    install_deps = typed_mock(Dev::Builtins::InstallDepsCommand)
    command = Dev::Builtins::UpCommand.new(install_deps_command: install_deps, host_service: host_service)
    context = Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui))

    When "running up outside any project"
    stdout = capture_stdout { command.call(args: [], context: context) }

    Then "deps install and credentials never run, and the bootstrap message points at projects"
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

  test "call brings the service dependencies up, in order, after the deps install they may depend on — through the port, not the CLI" do
    Given "two service dependencies; deps install and both bring-ups observed in order"
    order = sequence("deps, then services in order")
    install_deps = typed_mock(Dev::Builtins::InstallDepsCommand)
    install_deps.expects(:call).once.in_sequence(order)
    context = build_context(build_container: container_config(build_args: {}))
    first = typed_mock(Dev::Builtins::ContainerUpCommand)
    second = typed_mock(Dev::Builtins::ContainerUpCommand)
    first.expects(:up).with(project: context.project).once.in_sequence(order)
    second.expects(:up).with(project: context.project).once.in_sequence(order)
    first.expects(:call).never
    command = Dev::Builtins::UpCommand.new(
      install_deps_command: install_deps, host_service: quiet_host_service, service_dependencies: [first, second],
    )

    When "running up"
    command.call(args: [], context: context)

    Then "asserted on the mocks: the services are ready before the first command that needs them"
    true
  end

  test "inside the container, call is the deps install alone: no host converge, credentials or service bring-up" do
    Given "an inside up command whose host service and service dependency must stay untouched"
    host_service = typed_mock(Dev::HostService)
    install_deps = typed_mock(Dev::Builtins::InstallDepsCommand)
    service = typed_mock(Dev::Builtins::ContainerUpCommand)
    context = build_context(build_container: container_config(build_args: { "TOKEN" => "wwise/token" }))
    command = Dev::Builtins::UpCommand.new(
      install_deps_command: install_deps, host_service: host_service,
      service_dependencies: [service], inside_container: true,
    )

    When "running up inside"
    command.call(args: ["--group", "app"], context: context)

    Then "only the install body ran, with the user's args"
    1 * install_deps.call(args: ["--group", "app"], context: context)
    0 * host_service.converge_tooling
    0 * host_service.install_rc_hook
    0 * host_service.install_skills
    0 * Dev::Credentials.resolve_build_args(anything)
    0 * service.up(project: anything)
  end

  test "inside the container without a project, call explains there is nothing to provision" do
    Given "an inside up command and a projectless context"
    host_service = typed_mock(Dev::HostService)
    install_deps = typed_mock(Dev::Builtins::InstallDepsCommand)
    command = Dev::Builtins::UpCommand.new(
      install_deps_command: install_deps, host_service: host_service, inside_container: true,
    )
    context = Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui))

    When "running up"
    stdout = capture_stdout { command.call(args: [], context: context) }

    Then "neither half runs and the message says why"
    0 * install_deps.call(args: anything, context: anything)
    0 * host_service.converge_tooling
    stdout.include?("dev: inside a container with no dev.yml — nothing to provision.")
  end

  test "call with no service dependencies is the deps install alone" do
    Given "a plain project"
    install_deps = typed_mock(Dev::Builtins::InstallDepsCommand)
    install_deps.expects(:call).once
    command = Dev::Builtins::UpCommand.new(
      install_deps_command: install_deps, host_service: quiet_host_service, service_dependencies: [],
    )

    When "running up"
    command.call(args: [], context: build_context)

    Then
    true
  end

  private

  def build_command
    install_deps = typed_mock(Dev::Builtins::InstallDepsCommand)
    install_deps.stubs(:call)
    Dev::Builtins::UpCommand.new(
      install_deps_command: install_deps, host_service: quiet_host_service, service_dependencies: [],
    )
  end

  def quiet_host_service
    host_service = typed_mock(Dev::HostService)
    host_service.stubs(:converge_tooling)
    host_service.stubs(:install_rc_hook).returns(:already_present)
    host_service.stubs(:install_skills)
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
        name: "TestProject",
        root: Pathname.new("/tmp/up-test"),
        ruby_version: "4.0.1",
        build_container: build_container,
      ),
    )
  end
end

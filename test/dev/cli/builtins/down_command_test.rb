# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/builtins/container_down_command"
require "dev/cli/builtins/down_command"
require "dev/container_engine"
require "dev/engine_provisioner"
require "pathname"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::Cli::Builtins::DownCommandTest < Minitest::Test
  include SorbetHelper

  OURS = Dev::ContainerEngine::RunningContainer.new(
    name: "dev-snappy-linux-9f86-content-4c2e", managed: true, project_root: "/Users/jp/src/snappy",
  )
  THEIRS = Dev::ContainerEngine::RunningContainer.new(name: "my-postgres", managed: false, project_root: nil)

  test "traits: a visible Environment verb, staleness-exempt, no stamp" do
    Given "the builtin"
    command = down_command(services: [], provisioner: typed_mock(Dev::EngineProvisioner))

    Expect
    command.category == Dev::Cli::Command::Category::Environment
    command.staleness_exempt? == true
    command.stamps? == false
    !command.hidden?
  end

  test "down brings the service dependencies down in reverse order — through the port — then stops the idle engine" do
    Given "two service dependencies and a stoppable engine that is idle once they are down"
    order = sequence("services in reverse, then engine")
    context = project
    first = typed_mock(Dev::Cli::Builtins::ContainerDownCommand)
    second = typed_mock(Dev::Cli::Builtins::ContainerDownCommand)
    provisioner = typed_mock(Dev::EngineProvisioner)
    engine = typed_mock(Dev::ContainerEngine)
    # call order: a service's dependents come down before it, and every service before the engine hosting them stops
    second.expects(:down).with(project: context.project).once.in_sequence(order)
    first.expects(:down).with(project: context.project).once.in_sequence(order)
    provisioner.expects(:stop!).once.in_sequence(order)
    out = StringIO.new

    When "bringing the project down"
    down_command(services: [first, second], provisioner:, out:).call(args: no_args, context: context)

    Then
    0 * first.call
    _ * provisioner.stoppable? >> true
    _ * provisioner.engine >> engine
    _ * engine.running_containers >> []
    out.string == "dev: engine stopped.\n"
  end

  test "down leaves the engine running when #{description}, and says who is using it" do
    Given "an engine still serving #{description}"
    service = typed_mock(Dev::Cli::Builtins::ContainerDownCommand)
    provisioner = typed_mock(Dev::EngineProvisioner)
    engine = typed_mock(Dev::ContainerEngine)
    out = StringIO.new

    When "bringing the project down"
    down_command(services: [service], provisioner:, out:).call(args: no_args, context: project)

    Then "informational, exit 0 — dev engine down is the verb that reaches further"
    _ * service.down
    _ * provisioner.stoppable? >> true
    _ * provisioner.engine >> engine
    _ * engine.running_containers >> running
    0 * provisioner.stop!
    out.string == "dev: engine left running — still in use by:\n#{listed}"

    Where
    description                        | running         | listed
    "another checkout's container"     | [OURS]          | "  snappy (~/src/snappy)\n"
    "a container dev does not manage"  | [THEIRS]        | "  my-postgres (not managed by dev)\n"
    "both"                             | [OURS, THEIRS]  | "  snappy (~/src/snappy)\n  my-postgres (not managed by dev)\n"
  end

  test "down never tries to stop an engine dev did not provision" do
    Given "an explicit DOCKER_HOST (or Docker Desktop) engine"
    service = typed_mock(Dev::Cli::Builtins::ContainerDownCommand)
    provisioner = typed_mock(Dev::EngineProvisioner)
    out = StringIO.new

    When "bringing the project down"
    down_command(services: [service], provisioner:, out:).call(args: no_args, context: project)

    Then
    1 * service.down
    _ * provisioner.stoppable? >> false
    0 * provisioner.engine
    0 * provisioner.stop!
    out.string == "dev: engine left running (not managed by dev).\n"
  end

  private

  def down_command(services:, provisioner:, out: StringIO.new)
    Dev::Cli::Builtins::DownCommand.new(
      service_dependencies: services, provisioner: provisioner, out: out, home: "/Users/jp",
    )
  end

  def project
    Dev::Cli::ExecutionContext.new(
      ui: typed_mock(Dev::Ui),
      project: Dev::Cli::ProjectContext.new(name: "TestProject", root: Pathname.new("/tmp/down-test")),
    )
  end
end

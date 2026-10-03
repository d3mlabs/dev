# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/container_down_command"
require "dev/builtins/down_command"
require "dev/build_container_config"
require "dev/container_engine"
require "dev/engine_provisioner"
require "pathname"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::DownCommandTest < Minitest::Test
  include SorbetHelper

  OURS = Dev::ContainerEngine::RunningContainer.new(
    name: "dev-snappy-linux-9f86-content-4c2e", managed: true, project_root: "/Users/jp/src/snappy",
  )
  THEIRS = Dev::ContainerEngine::RunningContainer.new(name: "my-postgres", managed: false, project_root: nil)

  test "traits: a visible Lifecycle verb, staleness-exempt, no stamp" do
    Given "the builtin"
    command = down_command(services: [], provisioner: typed_mock(Dev::EngineProvisioner))

    Expect
    command.category == Dev::Command::Category::Lifecycle
    command.staleness_exempt? == true
    command.stamps? == false
    !command.hidden?
  end

  test "down brings the service dependencies down in reverse order — through the port — then stops the idle engine" do
    Given "two service dependencies and a stoppable engine that is idle once they are down"
    order = sequence("services in reverse, then engine")
    context = project
    first = typed_mock(Dev::Builtins::ContainerDownCommand)
    second = typed_mock(Dev::Builtins::ContainerDownCommand)
    second.expects(:down).with(project: context.project).once.in_sequence(order)
    first.expects(:down).with(project: context.project).once.in_sequence(order)
    first.expects(:call).never
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.stubs(:stoppable?).returns(true)
    provisioner.stubs(:engine).returns(engine_with([]))
    provisioner.expects(:stop!).once.in_sequence(order)
    out = StringIO.new

    When "bringing the project down"
    down_command(services: [first, second], provisioner:, out:).call(args: [], context: context)

    Then
    out.string == "dev: engine stopped.\n"
  end

  test "down leaves the engine running when #{description}, and says who is using it" do
    Given "an engine still serving #{description}"
    service = typed_mock(Dev::Builtins::ContainerDownCommand)
    service.stubs(:down)
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.stubs(:stoppable?).returns(true)
    provisioner.stubs(:engine).returns(engine_with(running))
    provisioner.expects(:stop!).never
    out = StringIO.new

    When "bringing the project down"
    down_command(services: [service], provisioner:, out:).call(args: [], context: project)

    Then "informational, exit 0 — dev engine down is the verb that reaches further"
    out.string == "dev: engine left running — still in use by:\n#{listed}"

    Where
    description                        | running         | listed
    "another checkout's container"     | [OURS]          | "  snappy (~/src/snappy)\n"
    "a container dev does not manage"  | [THEIRS]        | "  my-postgres (not managed by dev)\n"
    "both"                             | [OURS, THEIRS]  | "  snappy (~/src/snappy)\n  my-postgres (not managed by dev)\n"
  end

  test "down never tries to stop an engine dev did not provision" do
    Given "an explicit DOCKER_HOST (or Docker Desktop) engine"
    service = typed_mock(Dev::Builtins::ContainerDownCommand)
    service.expects(:down).once
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.stubs(:stoppable?).returns(false)
    provisioner.expects(:engine).never
    provisioner.expects(:stop!).never
    out = StringIO.new

    When "bringing the project down"
    down_command(services: [service], provisioner:, out:).call(args: [], context: project)

    Then
    out.string == "dev: engine left running (not managed by dev).\n"
  end

  private

  def engine_with(records)
    engine = typed_mock(Dev::ContainerEngine)
    engine.stubs(:running_containers).returns(records)
    engine
  end

  def down_command(services:, provisioner:, out: StringIO.new)
    Dev::Builtins::DownCommand.new(
      service_dependencies: services, provisioner: provisioner, out: out, home: "/Users/jp",
    )
  end

  def project
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui),
      project: Dev::ProjectContext.new(
        name: "TestProject", root: Pathname.new("/tmp/down-test"), ruby_version: "4.0.1",
        build_container: Dev::BuildContainerConfig.new(image: "myapp-linux", registry: "myregistry", persist: true),
      ),
    )
  end
end

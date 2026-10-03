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
    command = down_command(container_down: typed_mock(Dev::Builtins::ContainerDownCommand),
      provisioner: typed_mock(Dev::EngineProvisioner))

    Expect
    command.category == Dev::Command::Category::Lifecycle
    command.staleness_exempt? == true
    command.stamps? == false
    !command.hidden?
  end

  test "down brings this checkout's container down, then stops the engine when nothing else runs in it" do
    Given "a stoppable engine that is idle once our container is down"
    order = sequence("container before engine")
    container_down = typed_mock(Dev::Builtins::ContainerDownCommand)
    context = project
    container_down.expects(:call).with(args: [], context: context).once.in_sequence(order)
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.stubs(:stoppable?).returns(true)
    provisioner.stubs(:engine).returns(engine_with([]))
    provisioner.expects(:stop!).once.in_sequence(order)
    out = StringIO.new

    When "bringing the project down"
    down_command(container_down:, provisioner:, out:).call(args: [], context: context)

    Then
    out.string == "dev: engine stopped.\n"
  end

  test "down leaves the engine running when #{description}, and says who is using it" do
    Given "an engine still serving #{description}"
    container_down = typed_mock(Dev::Builtins::ContainerDownCommand)
    container_down.stubs(:call)
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.stubs(:stoppable?).returns(true)
    provisioner.stubs(:engine).returns(engine_with(running))
    provisioner.expects(:stop!).never
    out = StringIO.new

    When "bringing the project down"
    down_command(container_down:, provisioner:, out:).call(args: [], context: project)

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
    container_down = typed_mock(Dev::Builtins::ContainerDownCommand)
    container_down.expects(:call).once
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.stubs(:stoppable?).returns(false)
    provisioner.expects(:engine).never
    provisioner.expects(:stop!).never
    out = StringIO.new

    When "bringing the project down"
    down_command(container_down:, provisioner:, out:).call(args: [], context: project)

    Then
    out.string == "dev: engine left running (not managed by dev).\n"
  end

  private

  def engine_with(records)
    engine = typed_mock(Dev::ContainerEngine)
    engine.stubs(:running_containers).returns(records)
    engine
  end

  def down_command(container_down:, provisioner:, out: StringIO.new)
    Dev::Builtins::DownCommand.new(
      container_down_command: container_down, provisioner: provisioner, out: out, home: "/Users/jp",
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

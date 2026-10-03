# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/engine_up_command"
require "dev/builtins/engine_down_command"
require "dev/builtins/engine_status_command"
require "dev/build_container_config"
require "dev/confirmer"
require "dev/container_engine"
require "dev/engine_provisioner"
require "pathname"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::EngineCommandsTest < Minitest::Test
  include SorbetHelper

  MANAGED = Dev::ContainerEngine::RunningContainer.new(
    name: "dev-snappy-linux-9f86d08ab1-content-4c2e", managed: true, project_root: "/Users/jp/src/snappy",
  )
  FOREIGN = Dev::ContainerEngine::RunningContainer.new(name: "my-postgres", managed: false, project_root: nil)

  test "#{klass} traits: global, exempt from staleness, never stamps, lifecycle section" do
    Given "the builtin"
    command = klass.new(provisioner: typed_mock(Dev::EngineProvisioner), out: StringIO.new)

    Expect
    command.staleness_exempt? == true
    command.stamps? == false
    command.category == Dev::Command::Category::Lifecycle
    command.hidden? == false
    !command.desc.empty?

    Where
    klass                                | _
    Dev::Builtins::EngineUpCommand       | 0
    Dev::Builtins::EngineDownCommand     | 0
    Dev::Builtins::EngineStatusCommand   | 0
  end

  # --- up ---------------------------------------------------------------------

  test "engine up provisions the engine sized from the project's resources hint" do
    Given "a containerized project with a hint"
    resources = Dev::BuildContainerConfig::Resources.new(cpus: 8, memory_gib: 24)
    config = typed_mock(Dev::BuildContainerConfig)
    config.stubs(:resources).returns(resources)
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.expects(:provision!).with(resources: resources).once
    out = StringIO.new

    When "bringing the engine up"
    Dev::Builtins::EngineUpCommand.new(provisioner: provisioner, out: out)
      .call(args: [], context: project_context(build_container: config))

    Then
    out.string == "dev: engine up.\n"
  end

  test "engine up outside a project (or in one without a container) provisions at the engine's defaults" do
    Given "#{description}"
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.expects(:provision!).with(resources: nil).once
    context = in_project ? project_context(build_container: nil) : no_project

    When "bringing the engine up"
    Dev::Builtins::EngineUpCommand.new(provisioner: provisioner, out: StringIO.new).call(args: [], context: context)

    Then
    true

    Where
    description                      | in_project
    "no project"                     | false
    "a project without a container"  | true
  end

  # --- down -------------------------------------------------------------------

  def engine_with(records)
    engine = typed_mock(Dev::ContainerEngine)
    engine.stubs(:running_containers).returns(records)
    engine
  end

  def down_command(engine:, provisioner:, confirmer: typed_mock(Dev::Confirmer), out: StringIO.new)
    provisioner.stubs(:engine).returns(engine)
    Dev::Builtins::EngineDownCommand.new(provisioner: provisioner, confirmer: confirmer, out: out, home: "/Users/jp")
  end

  test "engine down on an idle engine just stops it" do
    Given "nothing running"
    engine = engine_with([])
    engine.expects(:run).never
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.expects(:assert_stoppable!).once
    provisioner.expects(:stop!).once
    out = StringIO.new

    When "bringing the engine down"
    down_command(engine: engine, provisioner: provisioner, out: out).call(args: [], context: no_project)

    Then
    out.string == "dev: engine stopped.\n"
  end

  test "engine down stops dev's own containers from any checkout without asking, then the engine" do
    Given "one managed container running"
    order = sequence("containers then engine")
    engine = engine_with([MANAGED])
    engine.expects(:run).with(["stop", "-t", "0", MANAGED.name], out: File::NULL, err: File::NULL)
      .once.in_sequence(order).returns(true)
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.stubs(:assert_stoppable!)
    provisioner.expects(:stop!).once.in_sequence(order)
    confirmer = typed_mock(Dev::Confirmer)
    confirmer.expects(:confirm?).never
    out = StringIO.new

    When "bringing the engine down"
    down_command(engine: engine, provisioner: provisioner, confirmer: confirmer, out: out).call(args: [], context: no_project)

    Then "the checkout is named, not the container"
    out.string == "dev: stopped build container: snappy (~/src/snappy)\ndev: engine stopped.\n"
  end

  test "engine down fails loudly when a container will not stop, leaving the engine up" do
    Given "a managed container whose stop fails"
    engine = engine_with([MANAGED])
    engine.stubs(:run).returns(false)
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.stubs(:assert_stoppable!)
    provisioner.expects(:stop!).never

    When "bringing the engine down"
    error = assert_raises(Dev::Builtins::EngineDownCommand::StopFailedError) do
      down_command(engine: engine, provisioner: provisioner).call(args: [], context: no_project)
    end

    Then "the container is named"
    error.message == "could not stop container #{MANAGED.name}."
  end

  test "engine down asks before stopping containers dev does not manage: #{description}" do
    Given "a foreign container running and a user who answers #{answer}"
    engine = engine_with([FOREIGN])
    stop = engine.expects(:run).with(["stop", "-t", "0", FOREIGN.name], out: File::NULL, err: File::NULL).returns(true)
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.stubs(:assert_stoppable!)
    confirmer = typed_mock(Dev::Confirmer)
    confirmer.expects(:confirm?).with { |question| question.include?("stop") }.once.returns(answer)
    if answer
      stop.once
      provisioner.expects(:stop!).once
    else
      stop.never
      provisioner.expects(:stop!).never
    end
    out = StringIO.new

    When "bringing the engine down"
    error = begin
      down_command(engine: engine, provisioner: provisioner, confirmer: confirmer, out: out).call(args: [], context: no_project)
      nil
    rescue Dev::Builtins::EngineDownCommand::EngineBusyError => e
      e
    end

    Then "the foreign container is listed first; a no is a refusal naming it"
    out.string.include?("my-postgres (not managed by dev)")
    error.nil? == answer
    error.nil? || error.message.include?("my-postgres")

    Where
    description | answer
    "yes"       | true
    "no"        | false
  end

  test "engine down --force stops everything without asking" do
    Given "a managed and a foreign container"
    engine = engine_with([MANAGED, FOREIGN])
    engine.expects(:run).with(["stop", "-t", "0", MANAGED.name], out: File::NULL, err: File::NULL).once.returns(true)
    engine.expects(:run).with(["stop", "-t", "0", FOREIGN.name], out: File::NULL, err: File::NULL).once.returns(true)
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.stubs(:assert_stoppable!)
    provisioner.expects(:stop!).once
    confirmer = typed_mock(Dev::Confirmer)
    confirmer.expects(:confirm?).never

    When "forcing the engine down"
    down_command(engine: engine, provisioner: provisioner, confirmer: confirmer).call(args: ["--force"], context: no_project)

    Then
    true
  end

  test "engine down on an engine dev does not own refuses before touching any container" do
    Given "an explicit DOCKER_HOST with a managed container running"
    engine = engine_with([MANAGED])
    engine.expects(:run).never
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.expects(:assert_stoppable!).raises(Dev::EngineProvisioner::UnmanagedEngineError, "DOCKER_HOST is set")
    provisioner.expects(:stop!).never

    When "bringing the engine down"
    down_command(engine: engine, provisioner: provisioner).call(args: [], context: no_project)

    Then
    raises Dev::EngineProvisioner::UnmanagedEngineError
  end

  # --- status -----------------------------------------------------------------

  def status(kind:, running:, stoppable:, resources:, colima: nil, linux: nil, wsl: nil, containers: [])
    Dev::EngineProvisioner::EngineStatus.new(
      kind: kind, running: running, stoppable: stoppable, resources: resources,
      colima: colima, linux: linux, wsl: wsl, containers: containers,
    )
  end

  def status_output(engine_status)
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.stubs(:status).returns(engine_status)
    out = StringIO.new
    Dev::Builtins::EngineStatusCommand.new(provisioner: provisioner, out: out, home: "/Users/jp")
      .call(args: [], context: no_project)
    out.string
  end

  test "engine status on colima: the VM line, then what runs in it" do
    Given "a running VM with one managed and one foreign container"
    report = status(
      kind: :colima, running: true, stoppable: true, resources: Dev::EngineResources.new(cpus: 8, memory_gib: 16),
      colima: Dev::ColimaProvisioner::Vm.new(running: true, cpus: 8, memory_gib: 16), containers: [MANAGED, FOREIGN],
    )

    Expect
    status_output(report) == <<~OUT
      engine: colima VM — running, 8 cpus / 16 GiB
      containers running:
        snappy (~/src/snappy)
        my-postgres (not managed by dev)
    OUT
  end

  test "engine status on a stopped or absent colima VM says so and has nothing to list" do
    Given "#{description}"
    report = status(kind: :colima, running: false, stoppable: true, resources: resources, colima: vm)

    Expect
    status_output(report) == expected

    Where
    description | vm | resources | expected
    "stopped"   | Dev::ColimaProvisioner::Vm.new(running: false, cpus: 4, memory_gib: 8) | Dev::EngineResources.new(cpus: 4, memory_gib: 8) | "engine: colima VM — stopped, 4 cpus / 8 GiB\ncontainers running: none\n"
    "absent"    | nil | nil | "engine: colima VM — not created (dev engine up creates it)\ncontainers running: none\n"
  end

  test "engine status on bare Linux: the daemon line and its converge facts" do
    Given "an active dockerd with everything converged"
    linux = Dev::LinuxEngineProvisioner::Status.new(
      docker_path: "/usr/bin/docker", desktop_shim: false, dockerd_active: true, buildx: true,
      in_docker_group: true, systemd_enabled: nil,
    )
    report = status(kind: :docker, running: true, stoppable: true,
      resources: Dev::EngineResources.new(cpus: 12, memory_gib: 32), linux: linux)

    Expect
    status_output(report) == <<~OUT
      engine: dockerd — running, 12 cpus / 32 GiB
      dockerd: converged (docker group, buildx)
      containers running: none
    OUT
  end

  test "engine status on Linux names what is not converged, including a Docker Desktop shim" do
    Given "a distro where Desktop's shim owns docker and the user is not in the group"
    linux = Dev::LinuxEngineProvisioner::Status.new(
      docker_path: "/usr/bin/docker", desktop_shim: true, dockerd_active: false, buildx: false,
      in_docker_group: false, systemd_enabled: false,
    )
    report = status(kind: :docker, running: false, stoppable: true, resources: nil, linux: linux)

    Expect
    status_output(report) == <<~OUT
      engine: dockerd — stopped
      dockerd: not converged — Docker Desktop shim owns docker, not in the docker group, no buildx, systemd off in wsl.conf (dev engine up fixes this)
      containers running: none
    OUT
  end

  test "engine status on WSL2 adds the .wslconfig line: #{description}" do
    Given "the host facts"
    linux = Dev::LinuxEngineProvisioner::Status.new(
      docker_path: "/usr/bin/docker", desktop_shim: false, dockerd_active: true, buildx: true,
      in_docker_group: true, systemd_enabled: true,
    )
    wsl = Dev::WslHost::Status.new(
      interop: interop, configured_cpus: configured_cpus, configured_memory_gib: configured_memory,
      observed: Dev::EngineResources.new(cpus: 8, memory_gib: 24),
      hardware: interop ? Dev::EngineResources.new(cpus: 28, memory_gib: 64) : nil,
    )
    report = status(kind: :docker, running: true, stoppable: true,
      resources: Dev::EngineResources.new(cpus: 8, memory_gib: 24), linux: linux, wsl: wsl)

    Expect
    status_output(report).lines.fetch(2) == "#{wsl_line}\n"

    Where
    description          | interop | configured_cpus | configured_memory | wsl_line
    "in sync"            | true    | 8               | 24                | "wsl: .wslconfig 8 cpus / 24 GiB, VM running at 8 cpus / 24 GiB; hardware 28 cpus / 64 GiB"
    "restart pending"    | true    | 16              | 48                | "wsl: .wslconfig 16 cpus / 48 GiB, VM running at 8 cpus / 24 GiB — restart pending (wsl --shutdown from Windows); hardware 28 cpus / 64 GiB"
    "no sizing written"  | true    | nil             | nil               | "wsl: .wslconfig has no sizing (WSL defaults), VM running at 8 cpus / 24 GiB; hardware 28 cpus / 64 GiB"
    "interop off"        | false   | nil             | nil               | "wsl: VM running at 8 cpus / 24 GiB; .wslconfig unreadable (Windows interop is off)"
  end

  test "engine status on an explicit DOCKER_HOST reports the daemon and that dev will not manage it" do
    Given "#{description}"
    report = status(kind: :explicit, running: running, stoppable: false, resources: resources)

    Expect
    status_output(report).lines.fetch(0) == "#{line}\n"

    Where
    description | running | resources                                        | line
    "reachable" | true    | Dev::EngineResources.new(cpus: 4, memory_gib: 8) | "engine: DOCKER_HOST (yours, not managed by dev) — running, 4 cpus / 8 GiB"
    "down"      | false   | nil                                              | "engine: DOCKER_HOST (yours, not managed by dev) — not reachable"
  end

  test "engine status with a docker record on macOS names Docker Desktop as the unmanaged engine" do
    Given "bare docker on darwin, no linux facts"
    report = status(kind: :docker, running: true, stoppable: false, resources: Dev::EngineResources.new(cpus: 6, memory_gib: 12))

    Expect
    status_output(report).lines.fetch(0) == "engine: dockerd (Docker Desktop, not managed by dev) — running, 6 cpus / 12 GiB\n"
  end

  private

  def no_project
    Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui))
  end

  def project_context(build_container:)
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui),
      project: Dev::ProjectContext.new(
        name: "TestProject", root: Pathname.new("/tmp/engine-test"), ruby_version: "4.0.1",
        build_container: build_container,
      ),
    )
  end
end

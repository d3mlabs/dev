# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/builtins/engine_up_command"
require "dev/cli/builtins/engine_down_command"
require "dev/cli/builtins/engine_status_command"
require "dev/container_engine"
require "dev/engine_provisioner"
require "dev/engine_resources"
require "pathname"
require "stringio"
require "support/answering_ui"

transform!(RSpock::AST::Transformation)
class Dev::Cli::Builtins::EngineCommandsTest < Minitest::Test
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
    command.category == Dev::Cli::Command::Category::Environment
    command.hidden? == false
    !command.desc.empty?

    Where
    klass                                   | _
    Dev::Cli::Builtins::EngineUpCommand     | 0
    Dev::Cli::Builtins::EngineDownCommand   | 0
    Dev::Cli::Builtins::EngineStatusCommand | 0
  end

  # --- up ---------------------------------------------------------------------

  test "engine up provisions the engine sized from the project's engine hint" do
    Given "a project with an `engine:` block"
    resources = Dev::EngineResources::Hint.new(cpus: 8, memory_gib: 24)
    provisioner = typed_mock(Dev::EngineProvisioner)
    out = StringIO.new

    When "bringing the engine up"
    Dev::Cli::Builtins::EngineUpCommand.new(provisioner: provisioner, out: out)
      .call(args: no_args, context: project_context(engine: resources))

    Then
    1 * provisioner.provision!(resources: resources)
    out.string == "dev: engine up.\n"
  end

  test "engine up outside a project (or in one without a hint) provisions at the engine's defaults" do
    Given "#{description}"
    provisioner = typed_mock(Dev::EngineProvisioner)
    context = in_project ? project_context(engine: nil) : no_project

    When "bringing the engine up"
    Dev::Cli::Builtins::EngineUpCommand.new(provisioner: provisioner, out: StringIO.new).call(args: no_args, context: context)

    Then
    1 * provisioner.provision!(resources: nil)

    Where
    description                      | in_project
    "no project"                     | false
    "a project without a container"  | true
  end

  # --- down -------------------------------------------------------------------

  def down_command(provisioner:, out: StringIO.new)
    Dev::Cli::Builtins::EngineDownCommand.new(provisioner: provisioner, out: out, home: "/Users/jp")
  end

  test "engine down on an idle engine just stops it" do
    Given "nothing running"
    engine = typed_mock(Dev::ContainerEngine)
    provisioner = typed_mock(Dev::EngineProvisioner)
    out = StringIO.new

    When "bringing the engine down"
    down_command(provisioner: provisioner, out: out).call(args: no_args, context: no_project)

    Then
    _ * provisioner.engine >> engine
    _ * engine.running_containers >> []
    0 * engine.run
    1 * provisioner.assert_stoppable!
    1 * provisioner.stop!
    out.string == "dev: engine stopped.\n"
  end

  test "engine down stops dev's own containers from any checkout without asking, then the engine" do
    Given "one managed container running"
    order = sequence("containers then engine")
    engine = typed_mock(Dev::ContainerEngine)
    provisioner = typed_mock(Dev::EngineProvisioner)
    # call order: the containers stop before the engine hosting them does
    engine.expects(:run).with(["stop", "-t", "0", MANAGED.name], out: File::NULL, err: File::NULL)
      .once.in_sequence(order).returns(true)
    provisioner.expects(:stop!).once.in_sequence(order)
    ui = AnsweringUi.new
    out = StringIO.new

    When "bringing the engine down"
    down_command(provisioner: provisioner, out: out).call(args: no_args, context: no_project(ui:))

    Then "the checkout is named, not the container; nothing was asked"
    _ * provisioner.engine >> engine
    _ * engine.running_containers >> [MANAGED]
    _ * provisioner.assert_stoppable!
    out.string == "dev: stopped build container: snappy (~/src/snappy)\ndev: engine stopped.\n"
    ui.asked.empty?
  end

  test "engine down fails loudly when a container will not stop, leaving the engine up" do
    Given "a managed container whose stop fails"
    engine = typed_mock(Dev::ContainerEngine)
    provisioner = typed_mock(Dev::EngineProvisioner)

    When "bringing the engine down"
    error = assert_raises(Dev::Cli::Builtins::EngineDownCommand::StopFailedError) do
      down_command(provisioner: provisioner).call(args: no_args, context: no_project)
    end

    Then "the container is named"
    _ * provisioner.engine >> engine
    _ * engine.running_containers >> [MANAGED]
    _ * engine.run >> false
    _ * provisioner.assert_stoppable!
    0 * provisioner.stop!
    error.message == "could not stop container #{MANAGED.name}."
  end

  test "engine down asks through the Ui seam before stopping containers dev does not manage, no being the default: #{description} (dev#533)" do
    Given "a foreign container running and a terminal that answers #{answer.inspect}"
    engine = typed_mock(Dev::ContainerEngine)
    provisioner = typed_mock(Dev::EngineProvisioner)
    ui = AnsweringUi.new(answer:)
    out = StringIO.new

    When "bringing the engine down"
    error = begin
      down_command(provisioner: provisioner, out: out).call(args: no_args, context: no_project(ui:))
      nil
    rescue Dev::Cli::Builtins::EngineDownCommand::EngineBusyError => e
      e
    end

    Then "the foreign container is listed first; the question defaults to no; anything but yes is a refusal naming it"
    _ * provisioner.engine >> engine
    _ * engine.running_containers >> [FOREIGN]
    _ * provisioner.assert_stoppable!
    stops * engine.run(["stop", "-t", "0", FOREIGN.name], out: File::NULL, err: File::NULL) >> true
    stops * provisioner.stop!
    out.string.include?("my-postgres (not managed by dev)")
    ui.questions == [AnsweringUi::Question.new(text: "dev: stop them too?", default: false)]
    error.nil? == stopped
    error.nil? || error.message.include?("my-postgres")

    Where
    description      | answer | stopped | stops
    "yes"            | true   | true    | 1
    "no"             | false  | false   | 0
    "no terminal"    | nil    | false   | 0
  end

  test "engine down --force stops everything without asking" do
    Given "a managed and a foreign container"
    engine = typed_mock(Dev::ContainerEngine)
    provisioner = typed_mock(Dev::EngineProvisioner)
    ui = AnsweringUi.new

    When "forcing the engine down"
    command = down_command(provisioner: provisioner)
    command.call(args: parsed_args(command, ["--force"]), context: no_project(ui:))

    Then
    _ * provisioner.engine >> engine
    _ * engine.running_containers >> [MANAGED, FOREIGN]
    _ * provisioner.assert_stoppable!
    1 * engine.run(["stop", "-t", "0", MANAGED.name], out: File::NULL, err: File::NULL) >> true
    1 * engine.run(["stop", "-t", "0", FOREIGN.name], out: File::NULL, err: File::NULL) >> true
    1 * provisioner.stop!
    ui.asked.empty?
  end

  test "engine down on an engine dev does not own refuses before touching any container" do
    Given "an explicit DOCKER_HOST with a managed container running"
    engine = typed_mock(Dev::ContainerEngine)
    provisioner = typed_mock(Dev::EngineProvisioner)

    When "bringing the engine down"
    down_command(provisioner: provisioner).call(args: no_args, context: no_project)

    Then
    _ * provisioner.engine >> engine
    _ * engine.running_containers >> [MANAGED]
    0 * engine.run
    1 * provisioner.assert_stoppable! >> raises(Dev::EngineProvisioner::UnmanagedEngineError, "DOCKER_HOST is set")
    0 * provisioner.stop!
    raises Dev::EngineProvisioner::UnmanagedEngineError
  end

  # --- status -----------------------------------------------------------------

  def status(kind:, running:, stoppable:, resources:, colima: nil, linux: nil, wsl: nil, containers: [], prefix_volumes: [])
    Dev::EngineProvisioner::EngineStatus.new(
      kind: kind, running: running, stoppable: stoppable, resources: resources,
      colima: colima, linux: linux, wsl: wsl, containers: containers, prefix_volumes: prefix_volumes,
    )
  end

  def prefix_volume(name, user:, stale:, mounted_by: [])
    Dev::PrefixVolumes::Volume.new(name: name, user: user, stale: stale, mounted_by: mounted_by)
  end

  # Runs `engine status` over the provisioner and returns what it printed;
  # the test states the provisioner's report as an interaction.
  def status_output(provisioner)
    out = StringIO.new
    Dev::Cli::Builtins::EngineStatusCommand.new(provisioner: provisioner, out: out, home: "/Users/jp")
      .call(args: no_args, context: no_project)
    out.string
  end

  test "engine status on colima: the VM line, then what runs in it" do
    Given "a running VM with one managed and one foreign container"
    provisioner = typed_mock(Dev::EngineProvisioner)
    report = status(
      kind: :colima, running: true, stoppable: true, resources: Dev::EngineResources.new(cpus: 8, memory_gib: 16),
      colima: Dev::ColimaProvisioner::Vm.new(running: true, cpus: 8, memory_gib: 16, disk_gib: 100), containers: [MANAGED, FOREIGN],
      prefix_volumes: [prefix_volume("dev-linuxbrew", user: nil, stale: false)],
    )

    When "asking for the status"
    output = status_output(provisioner)

    Then
    _ * provisioner.status >> report
    output == <<~OUT
      engine: colima VM — running, 8 cpus / 16 GiB
      containers running:
        snappy (~/src/snappy)
        my-postgres (not managed by dev)
      prefix volumes:
        dev-linuxbrew (the VM's)
    OUT
  end

  test "engine status on a stopped or absent colima VM says so and has nothing to list" do
    Given "#{description}"
    provisioner = typed_mock(Dev::EngineProvisioner)
    report = status(kind: :colima, running: false, stoppable: true, resources: resources, colima: vm)

    When "asking for the status"
    output = status_output(provisioner)

    Then
    _ * provisioner.status >> report
    output == expected

    Where
    description | vm                                                                                    | resources                                        | expected
    "stopped"   | Dev::ColimaProvisioner::Vm.new(running: false, cpus: 4, memory_gib: 8, disk_gib: 100) | Dev::EngineResources.new(cpus: 4, memory_gib: 8) | "engine: colima VM — stopped, 4 cpus / 8 GiB\ncontainers running: none\nprefix volumes: none\n"
    "absent"    | nil                                                                                   | nil                                              | "engine: colima VM — not created (dev engine up creates it)\ncontainers running: none\nprefix volumes: none\n"
  end

  test "engine status on bare Linux: the daemon line and its converge facts" do
    Given "an active dockerd with everything converged"
    provisioner = typed_mock(Dev::EngineProvisioner)
    linux = Dev::LinuxEngineProvisioner::Status.new(
      docker_path: "/usr/bin/docker", desktop_shim: false, dockerd_active: true, buildx: true,
      in_docker_group: true, systemd_enabled: nil,
    )
    report = status(kind: :docker, running: true, stoppable: true,
      resources: Dev::EngineResources.new(cpus: 12, memory_gib: 32), linux: linux,
      prefix_volumes: [
        prefix_volume("dev-linuxbrew", user: nil, stale: true),
        prefix_volume("dev-linuxbrew-jpduchesne", user: "jpduchesne", stale: false),
        prefix_volume("dev-linuxbrew-runner", user: "runner", stale: false),
      ])

    When "asking for the status"
    output = status_output(provisioner)

    Then
    _ * provisioner.status >> report
    output == <<~OUT
      engine: dockerd — running, 12 cpus / 32 GiB
      dockerd: converged (docker group, buildx)
      containers running: none
      prefix volumes:
        dev-linuxbrew — stale: no host user (dev cache gc removes it)
        dev-linuxbrew-jpduchesne (jpduchesne)
        dev-linuxbrew-runner (runner)
    OUT
  end

  test "engine status on Linux names what is not converged, including a Docker Desktop shim" do
    Given "a distro where Desktop's shim owns docker and the user is not in the group"
    provisioner = typed_mock(Dev::EngineProvisioner)
    linux = Dev::LinuxEngineProvisioner::Status.new(
      docker_path: "/usr/bin/docker", desktop_shim: true, dockerd_active: false, buildx: false,
      in_docker_group: false, systemd_enabled: false,
    )
    report = status(kind: :docker, running: false, stoppable: true, resources: nil, linux: linux)

    When "asking for the status"
    output = status_output(provisioner)

    Then
    _ * provisioner.status >> report
    output == <<~OUT
      engine: dockerd — stopped
      dockerd: not converged — Docker Desktop shim owns docker, not in the docker group, no buildx, systemd off in wsl.conf (dev engine up fixes this)
      containers running: none
      prefix volumes: none
    OUT
  end

  test "engine status on WSL2 adds the .wslconfig line: #{description}" do
    Given "the host facts"
    provisioner = typed_mock(Dev::EngineProvisioner)
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

    When "asking for the status"
    output = status_output(provisioner)

    Then
    _ * provisioner.status >> report
    output.lines.fetch(2) == "#{wsl_line}\n"

    Where
    description          | interop | configured_cpus | configured_memory | wsl_line
    "in sync"            | true    | 8               | 24                | "wsl: .wslconfig 8 cpus / 24 GiB, VM running at 8 cpus / 24 GiB; hardware 28 cpus / 64 GiB"
    "restart pending"    | true    | 16              | 48                | "wsl: .wslconfig 16 cpus / 48 GiB, VM running at 8 cpus / 24 GiB — restart pending (wsl --shutdown from Windows); hardware 28 cpus / 64 GiB"
    "no sizing written"  | true    | nil             | nil               | "wsl: .wslconfig has no sizing (WSL defaults), VM running at 8 cpus / 24 GiB; hardware 28 cpus / 64 GiB"
    "interop off"        | false   | nil             | nil               | "wsl: VM running at 8 cpus / 24 GiB; .wslconfig unreadable (Windows interop is off)"
  end

  test "engine status on an explicit DOCKER_HOST reports the daemon and that dev will not manage it" do
    Given "#{description}"
    provisioner = typed_mock(Dev::EngineProvisioner)
    report = status(kind: :explicit, running: running, stoppable: false, resources: resources)

    When "asking for the status"
    output = status_output(provisioner)

    Then
    _ * provisioner.status >> report
    output.lines.fetch(0) == "#{line}\n"

    Where
    description | running | resources                                        | line
    "reachable" | true    | Dev::EngineResources.new(cpus: 4, memory_gib: 8) | "engine: DOCKER_HOST (yours, not managed by dev) — running, 4 cpus / 8 GiB"
    "down"      | false   | nil                                              | "engine: DOCKER_HOST (yours, not managed by dev) — not reachable"
  end

  test "engine status with a docker record on macOS names Docker Desktop as the unmanaged engine" do
    Given "bare docker on darwin, no linux facts"
    provisioner = typed_mock(Dev::EngineProvisioner)
    report = status(kind: :docker, running: true, stoppable: false, resources: Dev::EngineResources.new(cpus: 6, memory_gib: 12))

    When "asking for the status"
    output = status_output(provisioner)

    Then
    _ * provisioner.status >> report
    output.lines.fetch(0) == "engine: dockerd (Docker Desktop, not managed by dev) — running, 6 cpus / 12 GiB\n"
  end

  private

  def no_project(ui: typed_mock(Dev::Ui))
    Dev::Cli::ExecutionContext.new(ui:)
  end

  def project_context(engine:)
    Dev::Cli::ExecutionContext.new(
      ui: typed_mock(Dev::Ui),
      project: Dev::Cli::ProjectContext.new(
        name: "TestProject", root: Pathname.new("/tmp/engine-test"), engine: engine,
      ),
    )
  end
end

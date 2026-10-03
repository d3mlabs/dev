# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/build_container_config"
require "dev/colima_provisioner"
require "dev/container_engine"
require "dev/docker_cli_plugins"
require "dev/engine_provisioner"
require "dev/engine_resources_check"
require "dev/settings"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::EngineProvisionerTest < Minitest::Test
  include SorbetHelper

  # Hermetic settings so the machine's own container_engine record never
  # decides a test.
  def build_settings(dir, record: nil)
    if record
      path = File.join(dir, "user", "config.yml")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "container_engine: #{record}\n")
    end
    Dev::Settings.new(
      config_path: File.join(dir, "user", "config.yml"),
      system_config_path: File.join(dir, "system", "config.yml"),
    )
  end

  # A check that passes whatever it is shown; tests about the check pass
  # their own.
  def passing_check
    typed_mock(Dev::EngineResourcesCheck).tap { |check| check.stubs(:check!) }
  end

  # Linux collaborators that tolerate anything; tests about Linux pass their
  # own.
  def quiet_linux_engine
    typed_mock(Dev::LinuxEngineProvisioner).tap { |engine| engine.stubs(:provision!) }
  end

  def quiet_wsl
    typed_mock(Dev::WslProvisioner).tap { |wsl| wsl.stubs(:provision!) }
  end

  def wsl_host(wsl)
    typed_mock(Dev::WslHost).tap { |host| host.stubs(:wsl?).returns(wsl) }
  end

  def build(dir, host_os:, record: nil, colima:, cli_plugins:, resources_check: passing_check,
    linux_engine: quiet_linux_engine, wsl: quiet_wsl, on_wsl: false)
    Dev::EngineProvisioner.new(
      settings: build_settings(dir, record: record),
      colima: colima,
      cli_plugins: cli_plugins,
      resources_check: resources_check,
      linux_engine: linux_engine,
      wsl: wsl,
      wsl_host: wsl_host(on_wsl),
      host_os: host_os,
      env: {},
    )
  end

  test "on macOS with the default engine, up wires the docker CLI plugins then starts the colima VM sized from resources" do
    Given "a darwin host, no record, and a repo resources hint"
    dir = Dir.mktmpdir("dev-engine-provisioner-")
    order = sequence("plugins then VM")
    cli_plugins = typed_mock(Dev::DockerCliPlugins)
    cli_plugins.expects(:ensure!).once.in_sequence(order).returns(:added)
    colima = typed_mock(Dev::ColimaProvisioner)
    colima.expects(:provision!).with(cpus: 8, memory_gib: 24).once.in_sequence(order)
    resources = Dev::BuildContainerConfig::Resources.new(cpus: 8, memory_gib: 24)

    When "provisioning"
    build(dir, host_os: "darwin", colima: colima, cli_plugins: cli_plugins).provision!(resources: resources)

    Then "asserted on the mocks: plugins first (docker build needs buildx), then the VM"
    true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "after the colima step, the resources check reads the engine as it now stands — a VM the ratchet could not grow fails here" do
    Given "a darwin host, a hint, and a check that finds the VM still short"
    dir = Dir.mktmpdir("dev-engine-provisioner-")
    order = sequence("provision then verify")
    cli_plugins = typed_mock(Dev::DockerCliPlugins)
    cli_plugins.stubs(:ensure!).returns(:already_present)
    colima = typed_mock(Dev::ColimaProvisioner)
    colima.expects(:provision!).once.in_sequence(order)
    resources = Dev::BuildContainerConfig::Resources.new(cpus: 12, memory_gib: 24)
    check = typed_mock(Dev::EngineResourcesCheck)
    check.expects(:check!).once.in_sequence(order)
      .with { |engine:, hint:, actual:| engine.kind == :colima && hint == resources && actual.nil? }
      .raises(Dev::EngineResourcesCheck::UndersizedEngineError, "still 4 cpus")

    When "provisioning"
    build(dir, host_os: "darwin", colima: colima, cli_plugins: cli_plugins, resources_check: check)
      .provision!(resources: resources)

    Then "the check's verdict is up's verdict"
    error = raises Dev::EngineResourcesCheck::UndersizedEngineError
    error.message == "still 4 cpus"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "bare dockerd has nothing to start but is still measured against the hint, as the daemon reports itself" do
    Given "a linux host and a hint"
    dir = Dir.mktmpdir("dev-engine-provisioner-")
    cli_plugins = typed_mock(Dev::DockerCliPlugins)
    colima = typed_mock(Dev::ColimaProvisioner)
    resources = Dev::BuildContainerConfig::Resources.new(cpus: 12, memory_gib: 24)
    check = typed_mock(Dev::EngineResourcesCheck)
    check.expects(:check!).once.with { |engine:, hint:, actual:| engine.kind == :docker && hint == resources && actual.nil? }

    When "provisioning"
    build(dir, host_os: "linux", colima: colima, cli_plugins: cli_plugins, resources_check: check)
      .provision!(resources: resources)

    Then
    true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "no resources hint hands nil sizing to colima (its defaults apply)" do
    Given "a darwin host and no hint"
    dir = Dir.mktmpdir("dev-engine-provisioner-")
    cli_plugins = typed_mock(Dev::DockerCliPlugins)
    cli_plugins.stubs(:ensure!).returns(:already_present)
    colima = typed_mock(Dev::ColimaProvisioner)
    colima.expects(:provision!).with(cpus: nil, memory_gib: nil).once

    When "provisioning"
    build(dir, host_os: "darwin", colima: colima, cli_plugins: cli_plugins).provision!(resources: nil)

    Then
    true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "on bare linux up converges dockerd and skips the macOS and WSL steps" do
    Given "a linux host (not WSL) with the bare-dockerd default"
    dir = Dir.mktmpdir("dev-engine-provisioner-")
    cli_plugins = typed_mock(Dev::DockerCliPlugins)
    cli_plugins.expects(:ensure!).never
    colima = typed_mock(Dev::ColimaProvisioner)
    colima.expects(:provision!).never
    linux_engine = typed_mock(Dev::LinuxEngineProvisioner)
    linux_engine.expects(:provision!).once
    wsl = typed_mock(Dev::WslProvisioner)
    wsl.expects(:provision!).never

    When "provisioning"
    build(dir, host_os: "linux", colima: colima, cli_plugins: cli_plugins, linux_engine: linux_engine, wsl: wsl,
      on_wsl: false).provision!(resources: nil)

    Then
    true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "on WSL2 up converges dockerd, then ratchets .wslconfig from the hint, then measures the VM as WSL sized it (#197)" do
    Given "a WSL host and a hint"
    dir = Dir.mktmpdir("dev-engine-provisioner-")
    order = sequence("dockerd, then .wslconfig, then check")
    cli_plugins = typed_mock(Dev::DockerCliPlugins)
    cli_plugins.expects(:ensure!).never
    colima = typed_mock(Dev::ColimaProvisioner)
    colima.expects(:provision!).never
    linux_engine = typed_mock(Dev::LinuxEngineProvisioner)
    linux_engine.expects(:provision!).once.in_sequence(order)
    wsl = typed_mock(Dev::WslProvisioner)
    wsl.expects(:provision!).with(cpus: 12, memory_gib: 24).once.in_sequence(order)
    resources = Dev::BuildContainerConfig::Resources.new(cpus: 12, memory_gib: 24)
    vm = Dev::EngineResources.new(cpus: 28, memory_gib: 64)
    host = wsl_host(true)
    host.stubs(:observed).returns(vm)
    check = typed_mock(Dev::EngineResourcesCheck)
    check.expects(:check!).once.in_sequence(order)
      .with { |engine:, hint:, actual:| engine.kind == :docker && hint == resources && actual == vm }

    When "provisioning"
    Dev::EngineProvisioner.new(
      settings: build_settings(dir), colima: colima, cli_plugins: cli_plugins, resources_check: check,
      linux_engine: linux_engine, wsl: wsl, wsl_host: host, host_os: "linux", env: {},
    ).provision!(resources: resources)

    Then "asserted on the mocks: dockerd must run before `docker ps` can answer the busy question, and the check " \
         "is handed the hypervisor's size for the VM, not the daemon's MemTotal (a 64 GB VM's kernel reports 63)"
    true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a WSL restart-required stops up before the resources check — the message is the verdict" do
    Given "a WSL host whose ratchet wrote .wslconfig"
    dir = Dir.mktmpdir("dev-engine-provisioner-")
    cli_plugins = typed_mock(Dev::DockerCliPlugins)
    colima = typed_mock(Dev::ColimaProvisioner)
    wsl = typed_mock(Dev::WslProvisioner)
    wsl.expects(:provision!).raises(Dev::WslProvisioner::RestartRequiredError, "restart pending")
    check = typed_mock(Dev::EngineResourcesCheck)
    check.expects(:check!).never

    When "provisioning"
    error = assert_raises(Dev::WslProvisioner::RestartRequiredError) do
      build(dir, host_os: "linux", colima: colima, cli_plugins: cli_plugins, resources_check: check, wsl: wsl,
        on_wsl: true).provision!(resources: nil)
    end

    Then
    error.message == "restart pending"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a docker record on macOS opts out of the VM but still wires the brew CLI's plugins" do
    Given "a darwin host whose user recorded container_engine: docker"
    dir = Dir.mktmpdir("dev-engine-provisioner-")
    cli_plugins = typed_mock(Dev::DockerCliPlugins)
    cli_plugins.expects(:ensure!).once.returns(:already_present)
    colima = typed_mock(Dev::ColimaProvisioner)
    colima.expects(:provision!).never

    When "provisioning"
    build(dir, host_os: "darwin", record: "docker", colima: colima, cli_plugins: cli_plugins).provision!(resources: nil)

    Then
    true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  # --- status / stop! (the `dev engine` primitives) -------------------------

  # A docker CLI stand-in answering `docker info` and `docker ps` for the
  # engine the provisioner resolves; status reads both through it.
  def fake_engine(kind, cpus: 8, memory_gib: 16, containers: "")
    info = "#{cpus} #{memory_gib * 1024**3}"
    # `sh -c script args…` binds the first docker arg (the subcommand) to $0.
    script = "case \"$0\" in info) echo '#{info}';; ps) printf '#{containers}';; esac #"
    Dev::ContainerEngine.new(kind: kind, argv_prefix: ["sh", "-c", script])
  end

  def dead_engine(kind)
    Dev::ContainerEngine.new(kind: kind, argv_prefix: ["false"])
  end

  def build_with_engine(dir, engine:, host_os:, colima: typed_mock(Dev::ColimaProvisioner),
    linux_engine: quiet_linux_engine, on_wsl: false, wsl_host: nil)
    Dev::EngineProvisioner.new(
      settings: build_settings(dir), colima: colima, cli_plugins: typed_mock(Dev::DockerCliPlugins),
      resources_check: passing_check, linux_engine: linux_engine, wsl: quiet_wsl,
      wsl_host: wsl_host || wsl_host(on_wsl), host_os: host_os, env: {}, engine: engine,
    )
  end

  test "status on colima reports the VM as colima sees it, plus what runs in it" do
    Given "a running 8/16 VM with one managed and one foreign container"
    dir = Dir.mktmpdir("dev-engine-provisioner-")
    colima = typed_mock(Dev::ColimaProvisioner)
    colima.stubs(:status).returns(Dev::ColimaProvisioner::Vm.new(running: true, cpus: 8, memory_gib: 16))
    engine = fake_engine(:colima, containers: "dev-snappy\ttrue\t/src/snappy\npg\t\t\n")

    When "inspecting"
    status = build_with_engine(dir, engine: engine, host_os: "darwin", colima: colima).status

    Then "the VM facts come from colima; the resources are the VM's size; containers are the engine's records"
    status.kind == :colima
    status.running == true
    status.stoppable == true
    status.resources == Dev::EngineResources.new(cpus: 8, memory_gib: 16)
    status.colima&.cpus == 8
    status.linux.nil?
    status.wsl.nil?
    status.containers.map(&:name) == %w[dev-snappy pg]
    status.containers.fetch(0).project_root == "/src/snappy"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "status on colima with no VM at all is not running and has no resources" do
    Given "no colima profile"
    dir = Dir.mktmpdir("dev-engine-provisioner-")
    colima = typed_mock(Dev::ColimaProvisioner)
    colima.stubs(:status).returns(nil)

    When "inspecting"
    status = build_with_engine(dir, engine: dead_engine(:colima), host_os: "darwin", colima: colima).status

    Then
    status.running == false
    status.resources.nil?
    status.colima.nil?
    status.containers.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "status on bare Linux reports the daemon facts and the daemon's own size" do
    Given "an active converged dockerd on a 12/32 box"
    dir = Dir.mktmpdir("dev-engine-provisioner-")
    linux_status = Dev::LinuxEngineProvisioner::Status.new(
      docker_path: "/usr/bin/docker", desktop_shim: false, dockerd_active: true, buildx: true,
      in_docker_group: true, systemd_enabled: nil,
    )
    linux_engine = typed_mock(Dev::LinuxEngineProvisioner)
    linux_engine.stubs(:status).returns(linux_status)

    When "inspecting"
    status = build_with_engine(dir, engine: fake_engine(:docker, cpus: 12, memory_gib: 32), host_os: "linux",
      linux_engine: linux_engine).status

    Then
    status.kind == :docker
    status.running == true
    status.stoppable == true
    status.resources == Dev::EngineResources.new(cpus: 12, memory_gib: 32)
    status.linux == linux_status
    status.wsl.nil?
    status.colima.nil?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "status on WSL2 adds the host's .wslconfig facts and reports the VM's size as WSL sized it" do
    Given "a WSL distro whose .wslconfig asks for more than the VM got"
    dir = Dir.mktmpdir("dev-engine-provisioner-")
    linux_engine = typed_mock(Dev::LinuxEngineProvisioner)
    linux_engine.stubs(:status).returns(Dev::LinuxEngineProvisioner::Status.new(
      docker_path: "/usr/bin/docker", desktop_shim: false, dockerd_active: false, buildx: true,
      in_docker_group: true, systemd_enabled: true,
    ))
    wsl_status = Dev::WslHost::Status.new(
      interop: true, configured_cpus: 16, configured_memory_gib: 48,
      observed: Dev::EngineResources.new(cpus: 8, memory_gib: 24), hardware: Dev::EngineResources.new(cpus: 28, memory_gib: 64),
    )
    host = typed_mock(Dev::WslHost)
    host.stubs(:wsl?).returns(true)
    host.stubs(:status).returns(wsl_status)

    When "inspecting"
    status = build_with_engine(dir, engine: fake_engine(:docker), host_os: "linux", linux_engine: linux_engine,
      wsl_host: host).status

    Then "dockerd being stopped reads as not running; the VM's size is the host's to report"
    status.running == false
    status.resources == Dev::EngineResources.new(cpus: 8, memory_gib: 24)
    status.wsl == wsl_status
    status.wsl&.restart_pending? == true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "status on an explicit DOCKER_HOST reports only what the daemon says, and that dev will not stop it" do
    Given "a user engine that #{answers ? "answers" : "is down"}"
    dir = Dir.mktmpdir("dev-engine-provisioner-")
    engine = answers ? fake_engine(:explicit, cpus: 4, memory_gib: 8) : dead_engine(:explicit)

    When "inspecting"
    status = build_with_engine(dir, engine: engine, host_os: "linux").status

    Then
    status.kind == :explicit
    status.running == answers
    status.stoppable == false
    status.colima.nil? && status.linux.nil? && status.wsl.nil?

    Cleanup
    FileUtils.rm_rf(dir)

    Where
    answers | _
    true    | nil
    false   | nil
  end

  test "a docker record on macOS (Docker Desktop) is an engine dev did not provision — not stoppable" do
    Given "a darwin host riding bare docker"
    dir = Dir.mktmpdir("dev-engine-provisioner-")

    When "inspecting"
    status = build_with_engine(dir, engine: fake_engine(:docker), host_os: "darwin").status

    Then
    status.stoppable == false
    status.linux.nil?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "stop! on #{kind} (#{host_os}) delegates to the engine's own provisioner" do
    Given "that engine"
    dir = Dir.mktmpdir("dev-engine-provisioner-")
    colima = typed_mock(Dev::ColimaProvisioner)
    linux_engine = typed_mock(Dev::LinuxEngineProvisioner)
    (colima_stops ? colima : linux_engine).expects(:stop!).once
    (colima_stops ? linux_engine : colima).expects(:stop!).never

    When "stopping"
    build_with_engine(dir, engine: fake_engine(kind), host_os: host_os, colima: colima, linux_engine: linux_engine).stop!

    Then
    true

    Cleanup
    FileUtils.rm_rf(dir)

    Where
    kind    | host_os  | colima_stops
    :colima | "darwin" | true
    :docker | "linux"  | false
  end

  test "stop! refuses an engine dev does not own: #{description}" do
    Given "that engine"
    dir = Dir.mktmpdir("dev-engine-provisioner-")
    colima = typed_mock(Dev::ColimaProvisioner)
    colima.expects(:stop!).never
    linux_engine = typed_mock(Dev::LinuxEngineProvisioner)
    linux_engine.expects(:stop!).never

    When "stopping"
    build_with_engine(dir, engine: fake_engine(kind), host_os: host_os, colima: colima, linux_engine: linux_engine).stop!

    Then
    error = raises Dev::EngineProvisioner::UnmanagedEngineError
    error.message.include?(hint)

    Cleanup
    FileUtils.rm_rf(dir)

    Where
    description                 | kind      | host_os  | hint
    "an explicit DOCKER_HOST"   | :explicit | "linux"  | "DOCKER_HOST"
    "Docker Desktop on macOS"   | :docker   | "darwin" | "Docker Desktop"
  end

  test "an explicit DOCKER_HOST is the user's engine: up leaves it alone entirely" do
    Given "a host with DOCKER_HOST set"
    dir = Dir.mktmpdir("dev-engine-provisioner-")
    cli_plugins = typed_mock(Dev::DockerCliPlugins)
    cli_plugins.expects(:ensure!).never
    colima = typed_mock(Dev::ColimaProvisioner)
    colima.expects(:provision!).never
    linux_engine = typed_mock(Dev::LinuxEngineProvisioner)
    linux_engine.expects(:provision!).never
    wsl = typed_mock(Dev::WslProvisioner)
    wsl.expects(:provision!).never
    check = typed_mock(Dev::EngineResourcesCheck)
    check.expects(:check!).never
    provisioner = Dev::EngineProvisioner.new(
      settings: build_settings(dir), colima: colima, cli_plugins: cli_plugins, resources_check: check,
      linux_engine: linux_engine, wsl: wsl, wsl_host: wsl_host(true),
      host_os: host_os, env: { "DOCKER_HOST" => "ssh://build-box" },
    )

    When "provisioning"
    provisioner.provision!(resources: nil)

    Then
    true

    Cleanup
    FileUtils.rm_rf(dir)

    Where
    host_os  | _
    "darwin" | nil
    "linux"  | nil
  end
end

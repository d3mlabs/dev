# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/build_container_config"
require "dev/colima_provisioner"
require "dev/container_engine"
require "dev/docker_cli_plugins"
require "dev/engine_provisioner"
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

  def build(dir, host_os:, record: nil, colima:, cli_plugins:)
    Dev::EngineProvisioner.new(
      settings: build_settings(dir, record: record),
      colima: colima,
      cli_plugins: cli_plugins,
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

  test "on linux there is no VM to start and no brew CLI to wire: up does nothing" do
    Given "a linux host with the bare-dockerd default"
    dir = Dir.mktmpdir("dev-engine-provisioner-")
    cli_plugins = typed_mock(Dev::DockerCliPlugins)
    cli_plugins.expects(:ensure!).never
    colima = typed_mock(Dev::ColimaProvisioner)
    colima.expects(:provision!).never

    When "provisioning"
    build(dir, host_os: "linux", colima: colima, cli_plugins: cli_plugins).provision!(resources: nil)

    Then
    true

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

  test "an explicit DOCKER_HOST is the user's engine: up leaves it alone entirely" do
    Given "a darwin host with DOCKER_HOST set"
    dir = Dir.mktmpdir("dev-engine-provisioner-")
    cli_plugins = typed_mock(Dev::DockerCliPlugins)
    cli_plugins.expects(:ensure!).never
    colima = typed_mock(Dev::ColimaProvisioner)
    colima.expects(:provision!).never
    provisioner = Dev::EngineProvisioner.new(
      settings: build_settings(dir), colima: colima, cli_plugins: cli_plugins,
      host_os: "darwin", env: { "DOCKER_HOST" => "ssh://build-box" },
    )

    When "provisioning"
    provisioner.provision!(resources: nil)

    Then
    true

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

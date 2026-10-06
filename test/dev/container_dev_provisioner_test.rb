# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/container_dev_provisioner"
require "support/fake_container_engine"

transform!(RSpock::AST::Transformation)
class Dev::ContainerDevProvisionerTest < Minitest::Test
  include SorbetHelper

  SCRIPT = Dev::ContainerDevProvisioner::SCRIPT

  test "provision! is a no-op when the container's dev already reports the host's version" do
    Given "a container whose dev version equals the host's"
    engine = FakeContainerEngine.new(capture_result: "0.2.98\n")
    provisioner = Dev::ContainerDevProvisioner.new(engine: engine, host_version: "0.2.98")

    When "provisioning"
    result = provisioner.provision!("dev-snappy-abc-content-123")

    Then "the version was probed with docker exec and nothing was installed"
    result == :current
    engine.captures == [["exec", "dev-snappy-abc-content-123", "dev", "version"]]
    engine.runs.empty?
  end

  test "provision! installs the host's version when the container reports #{reported.inspect}" do
    Given "a container whose dev is #{label}"
    engine = FakeContainerEngine.new(capture_result: reported)
    provisioner = Dev::ContainerDevProvisioner.new(engine: engine, host_version: "0.2.98")

    When "provisioning"
    result = provisioner.provision!("dev-x")

    Then "the install script runs inside the container with the host's version as its argument"
    result == :installed
    engine.runs == [["exec", "dev-x", "sh", "-c", SCRIPT.read, "sh", "0.2.98"]]

    Where
    reported     | label
    ""           | "absent (the probe fails)"
    "0.2.97\n"   | "an older release"
    "0.2.99\n"   | "a newer release"
  end

  test "provision! raises ProvisionFailedError, naming container and version, when the install fails" do
    Given "an engine whose exec fails"
    engine = FakeContainerEngine.new(capture_result: "") { |_args| false }
    provisioner = Dev::ContainerDevProvisioner.new(engine: engine, host_version: "0.2.98")

    When "provisioning"
    provisioner.provision!("dev-x")

    Then
    error = raises Dev::ContainerDevProvisioner::ProvisionFailedError
    error.message.include?("dev-x")
    error.message.include?("0.2.98")
  end

  test "the install script is POSIX sh, takes the version as $1, and pins the tap at the release that shipped it" do
    Given "the script shipped beside dev's bin"
    script = SCRIPT.read

    Expect "its contract, readable from the text"
    script.start_with?("#!/bin/sh")
    script.include?("version=\"$1\"")
    script.include?("Formula/dev-core.rb")
    script.include?("brew install")
    SCRIPT.executable?
  end

  test "the install script re-syncs with brew reinstall, never uninstall: dev-core's dependencies stay put" do
    Given "the script shipped beside dev's bin"
    script = SCRIPT.read

    Expect "a swap of dev-core, not a removal that autoremoves rbenv, shadowenv, git, gh … with it"
    script.include?("brew reinstall --quiet d3mlabs/d3mlabs/dev-core")
    !script.include?("brew uninstall")
  end

  test "the install script parses under sh -n" do
    Expect "a clean syntax check"
    system("sh", "-n", SCRIPT.to_s)
  end
end

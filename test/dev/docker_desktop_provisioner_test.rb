# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/docker_desktop_provisioner"
require "support/fake_container_engine"

transform!(RSpock::AST::Transformation)
class Dev::DockerDesktopProvisionerTest < Minitest::Test
  test "provision! verifies the daemon answers through the resolved engine" do
    Given "an engine whose docker info succeeds"
    engine = FakeContainerEngine.new

    When "provisioning"
    Dev::DockerDesktopProvisioner.new(engine: engine).provision!

    Then "the probe rode the engine and nothing else happened"
    engine.runs == [["info"]]
  end

  test "provision! raises when the daemon does not answer (dev never starts the GUI app)" do
    Given "an engine whose docker info fails"
    engine = FakeContainerEngine.new { |_args| false }

    When "provisioning"
    Dev::DockerDesktopProvisioner.new(engine: engine).provision!

    Then
    raises Dev::DockerDesktopProvisioner::EngineUnreachableError
  end
end

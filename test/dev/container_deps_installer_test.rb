# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/container_deps_installer"

transform!(RSpock::AST::Transformation)
class ContainerDepsInstallerTest < Minitest::Test
  test "install! runs dev deps install in the container at the project mount, with the run_env injected" do
    Given "an engine that succeeds"
    engine = FakeContainerEngine.new
    installer = Dev::ContainerDepsInstaller.new(engine: engine)

    When "installing"
    installer.install!("dev-myapp-abc", env: { "WWISE_TOKEN" => "t0k" })

    Then "one docker exec, env first, in /project, running the builtin"
    engine.runs == [["exec", "-e", "WWISE_TOKEN=t0k", "-w", "/project", "dev-myapp-abc", "dev", "deps", "install"]]
  end

  test "install! raises InstallFailedError naming the container when the install exits nonzero" do
    Given "an engine whose exec fails"
    engine = FakeContainerEngine.new { |_args| false }
    installer = Dev::ContainerDepsInstaller.new(engine: engine)

    When "installing"
    installer.install!("dev-myapp-abc", env: {})

    Then "the failure is typed and names the container"
    error = raises Dev::ContainerDepsInstaller::InstallFailedError
    error.message.include?("dev-myapp-abc")
  end
end

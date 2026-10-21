# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/container_deps_installer"
require "support/fake_container_engine"

transform!(RSpock::AST::Transformation)
class ContainerDepsInstallerTest < Minitest::Test
  test "install! runs dev deps install in the container at the project mount, with the run_env injected" do
    Given "an engine that succeeds and a host with no gh login"
    engine = FakeContainerEngine.new
    installer = Dev::ContainerDepsInstaller.new(engine: engine, github_token: -> { nil })

    When "installing"
    installer.install!("dev-myapp-abc", env: { "WWISE_TOKEN" => "t0k" })

    Then "one docker exec, env first, in /project, running the builtin"
    engine.runs == [["exec", "-e", "WWISE_TOKEN=t0k", "-w", "/project", "dev-myapp-abc", "dev", "deps", "install"]]
  end

  test "install! hands the host's gh token to the container as GH_TOKEN: the container fetches its own private releases (ADR-0008)" do
    Given "an engine that succeeds and a host whose gh is logged in"
    engine = FakeContainerEngine.new
    installer = Dev::ContainerDepsInstaller.new(engine: engine, github_token: -> { "gho_secret" })

    When "installing"
    installer.install!("dev-myapp-abc", env: {})

    Then "the token rides the exec as -e, and only there"
    engine.runs == [["exec", "-e", "GH_TOKEN=gho_secret", "-w", "/project", "dev-myapp-abc", "dev", "deps", "install"]]
  end

  test "install! leaves a GH_TOKEN the run_env already names alone" do
    Given "a run_env carrying its own token and a host with a different one"
    engine = FakeContainerEngine.new
    installer = Dev::ContainerDepsInstaller.new(engine: engine, github_token: -> { "gho_host" })

    When "installing"
    installer.install!("dev-myapp-abc", env: { "GH_TOKEN" => "gho_project" })

    Then "the project's wins"
    engine.runs == [["exec", "-e", "GH_TOKEN=gho_project", "-w", "/project", "dev-myapp-abc", "dev", "deps", "install"]]
  end

  test "an empty token from the host (gh auth token printed nothing) injects nothing" do
    Given "a host whose gh answers with a blank line"
    engine = FakeContainerEngine.new
    installer = Dev::ContainerDepsInstaller.new(engine: engine, github_token: -> { "" })

    When "installing"
    installer.install!("dev-myapp-abc", env: {})

    Then "no -e at all"
    engine.runs == [["exec", "-w", "/project", "dev-myapp-abc", "dev", "deps", "install"]]
  end

  test "install! raises InstallFailedError naming the container when the install exits nonzero" do
    Given "an engine whose exec fails"
    engine = FakeContainerEngine.new { |_args| false }
    installer = Dev::ContainerDepsInstaller.new(engine: engine, github_token: -> { nil })

    When "installing"
    installer.install!("dev-myapp-abc", env: {})

    Then "the failure is typed and names the container"
    error = raises Dev::ContainerDepsInstaller::InstallFailedError
    error.message.include?("dev-myapp-abc")
  end
end

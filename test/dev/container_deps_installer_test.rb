# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/container_deps_installer"
require "fileutils"
require "support/fake_container_engine"
require "tmpdir"

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

  test "HOST_GH_TOKEN asks gh on the PATH and answers #{expected.inspect} when gh #{behaviour}" do
    Given "a PATH holding only a gh that #{behaviour}"
    dir = Dir.mktmpdir("gh-on-path-")
    if script
      File.write(File.join(dir, "gh"), "#!/bin/sh\n#{script}\n")
      File.chmod(0o755, File.join(dir, "gh"))
    end
    original_path = ENV["PATH"]
    ENV["PATH"] = dir

    When "asking for the host's token"
    token = Dev::ContainerDepsInstaller::HOST_GH_TOKEN.call

    Then
    token == expected

    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(dir)

    Where
    behaviour              | script                                  | expected
    "prints a token"       | 'echo "gho_fromhost"'                   | "gho_fromhost"
    "is not logged in"     | "echo 'not logged in' >&2; exit 1"      | nil
    "is not installed"     | nil                                     | nil
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

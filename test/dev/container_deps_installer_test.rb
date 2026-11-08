# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/build_container"
require "dev/container_deps_installer"
require "dev/container_github_token"
require "dev/environment_image"
require "dev/project_container"
require "pathname"
require "support/fake_container_engine"

transform!(RSpock::AST::Transformation)
class ContainerDepsInstallerTest < Minitest::Test
  ROOT = Pathname("/src/myapp")
  SHA = "0123456789abcdef0123456789abcdef01234567"

  test "install! runs dev deps install in the container's workspace at the snapshot, with the run_env injected" do
    Given "an engine that succeeds, a host with no gh login, and an image with a resolvable run_env"
    engine = FakeContainerEngine.new
    ENV["WWISE_TOKEN"] = "t0k"

    When "installing"
    installer(engine, token: nil).install!("dev-myapp-abc", image: image(run_env: { "WWISE_TOKEN" => "wwise/token" }), snapshot: snapshot)

    Then "one docker exec, the env named (bare -e, the value in the spawn env — dev#317), the workspace program fetching the snapshot then exec'ing the builtin"
    engine.runs.size == 1
    engine.runs.first[0, 4] == ["exec", "-e", "WWISE_TOKEN", "dev-myapp-abc"]
    engine.runs.first[4, 2] == ["sh", "-c"]
    engine.runs.first.last.include?("fetch -q --no-tags https://github.com/o/r.git #{snapshot.branch.ref}")
    engine.runs.first.last.include?("git reset -q --hard #{SHA}")
    engine.runs.first.last.end_with?("exec dev deps install\n")
    engine.run_envs == [{ "WWISE_TOKEN" => "t0k" }]

    Cleanup
    ENV.delete("WWISE_TOKEN")
  end

  test "install! hands the host's gh token to the container as GH_TOKEN: the container fetches the snapshot and its own private releases (ADR-0008)" do
    Given "an engine that succeeds and a host whose gh is logged in"
    engine = FakeContainerEngine.new

    When "installing"
    installer(engine, token: "gho_secret").install!("dev-myapp-abc", image: image, snapshot: snapshot)

    Then "the exec names GH_TOKEN; the value rides the spawn env and appears on no argv"
    engine.runs.first[0, 4] == ["exec", "-e", "GH_TOKEN", "dev-myapp-abc"]
    engine.runs.first.none? { |part| part.include?("gho_secret") }
    engine.run_envs == [{ "GH_TOKEN" => "gho_secret" }]
  end

  test "install! raises InstallFailedError naming the container when the install exits nonzero" do
    Given "an engine whose exec fails"
    engine = FakeContainerEngine.new { |_args| 2 }

    When "installing"
    installer(engine, token: nil).install!("dev-myapp-abc", image: image, snapshot: snapshot)

    Then "the failure is typed and names the container"
    error = raises Dev::ContainerDepsInstaller::InstallFailedError
    error.message.include?("dev-myapp-abc")
  end

  private

  def installer(engine, token:)
    containers = Dev::ProjectContainer.new(
      project_root: ROOT,
      client: Dev::BuildContainer.new(engine:, host_os: "darwin"),
      github_token: Dev::ContainerGithubToken.new(source: -> { token }),
      repo_resolver: -> { "o/r\n" },
    )
    Dev::ContainerDepsInstaller.new(containers:)
  end

  def image(run_env: {})
    Dev::EnvironmentImage.new(
      name: "myapp-linux", from: "ghcr.io/d3mlabs/unreal-engine-build-base", from_digest: "a" * 64,
      platform: "linux/amd64", apt: [], registry: "ghcr.io/d3mlabs", run_env:,
    )
  end

  def snapshot
    @snapshot ||= Dev::Lifecycle::Snapshot.new(sha: SHA, branch: Dev::Lifecycle::SnapshotBranch.mint(runner: Dev::ContainerWorkspace::RUNNER))
  end
end

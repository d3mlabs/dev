# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/build_container"
require "dev/container_github_token"
require "dev/container_workspace"
require "dev/engine_resources"
require "dev/engine_resources_check"
require "dev/environment_image"
require "dev/lifecycle/snapshot"
require "dev/lifecycle/snapshot_branch"
require "dev/project_container"
require "fileutils"
require "pathname"
require "stringio"
require "support/fake_container_engine"
require "tmpdir"

# The one way into the project's containers (dev#421): the engine is the
# true boundary (FakeContainerEngine records what reached it), the image
# step runs over it (a locally present image), and the repo is resolved
# without gh. The BuildContainer client is real.
transform!(RSpock::AST::Transformation)
class Dev::ProjectContainerTest < Minitest::Test
  include SorbetHelper

  ROOT = Pathname("/src/myapp")
  SHA = "0123456789abcdef0123456789abcdef01234567"

  test "destination names the image and that it is the container: what the crossing line says" do
    Expect
    containers(FakeContainerEngine.new).destination(image) == "in myapp-linux (container)"
  end

  test "assert_engine_up! refuses when the daemon does not answer, pointing at dev up; passes when it does" do
    When "an answering engine is asked, then a silent one"
    containers(FakeContainerEngine.new(capture_result: "12 #{24 * 1_073_741_824}")).assert_engine_up!
    containers(FakeContainerEngine.new(capture_result: "")).assert_engine_up!

    Then
    error = raises Dev::ProjectContainer::EngineUnavailableError
    error.message.include?("`dev up` brings it up")
  end

  test "run on a non-persisted image: the floor measured first, the image ensured, then one `docker run --rm` of the workspace program with the run_env and gh token named; the status comes back" do
    Given "an engine whose run exits 4, a floor to measure, a host gh login, and a resolvable run_env"
    engine = FakeContainerEngine.new(&->(args) { args.fetch(0) == "run" ? 4 : true })
    ENV["WWISE_TOKEN"] = "t0k"
    hint = Dev::EngineResources::Hint.new(cpus: 8)
    check = typed_mock(Dev::EngineResourcesCheck)
    check.expects(:check!).with(engine:, hint:).once
    subject = containers(engine, token: "gho_host", hint:, check:)

    When
    status = capture_stdout { subject.run(image(run_env: { "WWISE_TOKEN" => "wwise/token" }), argv: ["dev", "build", "x"], snapshot:) }

    Then "the inspect, the volumes, then the run: -e WWISE_TOKEN -e GH_TOKEN on argv, both values in the spawn env, the program ending in the command"
    status == 4
    engine.runs.map(&:first) == ["image", "volume", "volume", "run"]
    run = engine.runs.last
    run[0, 2] == ["run", "--rm"]
    run.each_cons(2).include?(["-e", "WWISE_TOKEN"])
    run.each_cons(2).include?(["-e", "GH_TOKEN"])
    run.include?(image.ref)
    run.last.include?("fetch -q --no-tags https://github.com/o/r.git #{snapshot.branch.ref}")
    run.last.end_with?("exec dev build x\n")
    engine.run_envs.last.slice("WWISE_TOKEN", "GH_TOKEN") == { "WWISE_TOKEN" => "t0k", "GH_TOKEN" => "gho_host" }

    Cleanup
    ENV.delete("WWISE_TOKEN")
  end

  test "run on a persisted image execs in its service container (here already up: the fake's inspect answers yes), never a one-shot run" do
    Given
    engine = FakeContainerEngine.new
    subject = containers(engine)

    When
    status = capture_stdout { subject.run(image(persist: true), argv: ["dev", "build", "x"], snapshot:) }

    Then "one exec against the service, the program as its command; no `docker run`"
    status == 0
    exec = engine.runs.find { |verb, *_rest| verb == "exec" }
    exec.include?(Dev::BuildContainer.service_container_name(image.ref, ROOT))
    exec.last.end_with?("exec dev build x\n")
    engine.runs.none? { |verb, *_rest| verb == "run" }
  end

  test "exec_in runs the program in the container the caller holds, the image's run_env riding in; no image step" do
    Given
    engine = FakeContainerEngine.new(&->(args) { args.fetch(0) == "exec" ? 2 : true })
    ENV["WWISE_TOKEN"] = "t0k"

    When
    status = containers(engine).exec_in("dev-myapp-cold-1", image: image(run_env: { "WWISE_TOKEN" => "wwise/token" }), argv: ["dev", "deps", "install"], snapshot:)

    Then
    status == 2
    engine.runs.size == 1
    engine.runs.first[0, 4] == ["exec", "-e", "WWISE_TOKEN", "dev-myapp-cold-1"]
    engine.runs.first.last.end_with?("exec dev deps install\n")
    engine.run_envs.first == { "WWISE_TOKEN" => "t0k" }

    Cleanup
    ENV.delete("WWISE_TOKEN")
  end

  test "the repo gh names is stripped and resolved once, on first use, never at construction" do
    Given "a resolver counting its calls"
    calls = 0
    resolver = lambda do
      calls += 1
      "d3mlabs/snappy\n"
    end
    engine = FakeContainerEngine.new
    subject = containers(engine, repo_resolver: resolver)

    When "two commands run"
    before = calls
    subject.exec_in("c", image:, argv: ["true"], snapshot:)
    subject.exec_in("c", image:, argv: ["true"], snapshot:)

    Then
    before == 0
    calls == 1
    engine.runs.all? { |*run| run.flatten.last.include?("https://github.com/d3mlabs/snappy.git") }
  end

  test "a checkout gh names no repo for is RepoUnresolvedError: the container has nowhere to fetch from" do
    When
    containers(FakeContainerEngine.new, repo_resolver: -> { "\n" }).exec_in("c", image:, argv: ["true"], snapshot:)

    Then
    error = raises Dev::ProjectContainer::RepoUnresolvedError
    error.message.include?(ROOT.to_s)
  end

  test "DEV_PUBLISH_IMAGE=1 asks the image step to publish; unset, it never pushes" do
    Given
    ENV["DEV_PUBLISH_IMAGE"] = publish ? "1" : nil
    engine = FakeContainerEngine.new
    client = Dev::BuildContainer.new(engine:, host_os: "darwin")
    client.expects(:ensure_environment_image!).with { |_image, publish:| publish == expected }.once.returns(image.ref)
    subject = containers(engine, client:)

    When
    subject.run(image, argv: ["true"], snapshot:)

    Then
    engine.runs.last.first == "run"

    Cleanup
    ENV.delete("DEV_PUBLISH_IMAGE")

    Where
    publish | expected
    true    | true
    false   | false
  end

  test "fetch is a no-op when the data root is shared (Linux): what the container wrote is already in the host's store" do
    Given
    engine = FakeContainerEngine.new

    When
    containers(engine, host_os: "linux").fetch(image, into: Pathname("/anywhere"))

    Then
    engine.runs.empty?
  end

  test "fetch on a Mac copies out of a one-shot container of the image, into the host's data root, and removes the container after" do
    Given "a data root for this test"
    root = Pathname(Dir.mktmpdir("project-container-"))
    original = ENV["DEV_DATA_ROOT"]
    ENV["DEV_DATA_ROOT"] = root.to_s
    into = root / "artifacts" / "myapp" / "win64"
    engine = FakeContainerEngine.new

    When
    capture_stdout { containers(engine, host_os: "darwin").fetch(image, into:) }

    Then "the copy names the same path under the container's data root, and rm -f follows"
    copy = engine.runs.find { |verb, *_rest| verb == "cp" }
    copy[1].end_with?(":/var/lib/dev/artifacts/myapp/win64/.")
    copy[1].start_with?(Dev::BuildContainer.service_container_name(image.ref, ROOT) + "-cold-")
    copy[2] == into.to_s
    engine.runs.last[0, 2] == ["rm", "-f"]
    into.directory?

    Cleanup
    ENV["DEV_DATA_ROOT"] = original
    FileUtils.rm_rf(root)
  end

  test "fetch into a path outside the host's data root is OutsideDataRootError before anything runs in a container" do
    Given
    root = Pathname(Dir.mktmpdir("project-container-"))
    original = ENV["DEV_DATA_ROOT"]
    ENV["DEV_DATA_ROOT"] = (root / "data").to_s
    engine = FakeContainerEngine.new

    When
    capture_stdout { containers(engine, host_os: "darwin").fetch(image, into: root / "elsewhere") }

    Then
    raises Dev::BuildContainer::OutsideDataRootError
    engine.runs.none? { |verb, *_rest| verb == "cp" }

    Cleanup
    ENV["DEV_DATA_ROOT"] = original
    FileUtils.rm_rf(root)
  end

  private

  def containers(engine, token: nil, hint: nil, check: passing_check, host_os: "darwin", repo_resolver: -> { "o/r" },
    client: Dev::BuildContainer.new(engine:, host_os:))
    Dev::ProjectContainer.new(
      project_root: ROOT, client:, engine_hint: hint, resources_check: check,
      github_token: Dev::ContainerGithubToken.new(source: -> { token }), repo_resolver:,
    )
  end

  def passing_check
    typed_mock(Dev::EngineResourcesCheck).tap { |check| check.stubs(:check!) }
  end

  def image(persist: false, run_env: {})
    Dev::EnvironmentImage.new(
      name: "myapp-linux", from: "ghcr.io/d3mlabs/unreal-engine-build-base", from_digest: "a" * 64,
      platform: "linux/amd64", apt: [], registry: "ghcr.io/d3mlabs", persist:, run_env:,
    )
  end

  test "the default repo resolver asks gh in the checkout, once called — never at construction" do
    Given "a checkout whose gh names a repo"
    root = Pathname("/proj")
    gh = typed_mock(Dev::Lifecycle::Gh)
    Dev::Lifecycle::Gh.expects(:new).with(root: root).once.returns(gh)
    gh.expects(:capture).with(Dev::ProjectContainer::REPO_QUERY).once.returns("d3mlabs/demo\n")

    When "resolving the default"
    resolved = Dev::ProjectContainer.default_repo_resolver(root).call

    Then "gh's answer comes back, as captured"
    resolved == "d3mlabs/demo\n"

    Cleanup
    nil
  end

  def snapshot
    @snapshot ||= Dev::Lifecycle::Snapshot.new(sha: SHA, branch: Dev::Lifecycle::SnapshotBranch.mint(runner: Dev::ContainerWorkspace::RUNNER))
  end

  def capture_stdout
    previous = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = previous
  end
end

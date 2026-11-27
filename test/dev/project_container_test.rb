# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/build_container"
require "dev/container_github_token"
require "dev/engine_resources"
require "dev/engine_resources_check"
require "dev/environment_image"
require "dev/lifecycle/snapshot"
require "dev/lifecycle/snapshot_branch"
require "dev/lifecycle/workspace"
require "dev/project_container"
require "fileutils"
require "pathname"
require "stringio"
require "support/fake_container_engine"
require "tmpdir"

# The one way into the project's containers (dev#421, dev#648): the
# engine is the true boundary (FakeContainerEngine records what reached
# it), the image step runs over it (a locally present image), and the
# checkout is a real directory — the mount pre-creates its shadowenv
# directories in it. The BuildContainer client is real.
transform!(RSpock::AST::Transformation)
class Dev::ProjectContainerTest < Minitest::Test
  include SorbetHelper

  SHA = "0123456789abcdef0123456789abcdef01234567"

  test "destination names the image and that it is the container: what the crossing line says" do
    Given
    root = checkout_root

    Expect
    containers(FakeContainerEngine.new, root:).destination(image) == "in myapp-linux (container)"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "assert_engine_up! refuses when the daemon does not answer, pointing at dev up; passes when it does" do
    Given
    root = checkout_root

    When "an answering engine is asked, then a silent one"
    containers(FakeContainerEngine.new(capture_result: "12 #{24 * 1_073_741_824}"), root:).assert_engine_up!
    containers(FakeContainerEngine.new(capture_result: ""), root:).assert_engine_up!

    Then
    error = raises Dev::ProjectContainer::EngineUnavailableError
    error.message.include?("`dev up` brings it up")

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "run on a non-persisted image: the floor measured first, the image ensured, then one `docker run --rm` in the mounted checkout with the run_env and gh token named; the status comes back" do
    Given "an engine whose run exits 4, a floor to measure, a host gh login, and a resolvable run_env"
    root = checkout_root
    engine = FakeContainerEngine.new(&->(args) { args.fetch(0) == "run" ? 4 : true })
    ENV["WWISE_TOKEN"] = "t0k"
    hint = Dev::EngineResources::Hint.new(cpus: 8)
    check = typed_mock(Dev::EngineResourcesCheck)
    subject = containers(engine, root:, token: "gho_host", hint:, check:)

    When
    status = capture_stdout { subject.run(image(run_env: { "WWISE_TOKEN" => "wwise/token" }), argv: ["dev", "build", "x"], workspace: mounted(root)) }

    Then "the inspect, the volumes, then the run: the checkout mounted at its path and the workdir, -e WWISE_TOKEN -e GH_TOKEN on argv, both values in the spawn env, the command word for word"
    1 * check.check!(engine:, hint:)
    status == 4
    engine.runs.map(&:first) == ["image", "volume", "volume", "run"]
    run = engine.runs.last
    run[0, 2] == ["run", "--rm"]
    run.each_cons(2).include?(["-v", "#{root}:#{root}"])
    run.each_cons(2).include?(["-w", root.to_s])
    run.each_cons(2).include?(["-e", "WWISE_TOKEN"])
    run.each_cons(2).include?(["-e", "GH_TOKEN"])
    run.include?(image.ref)
    run.last(3) == ["dev", "build", "x"]
    run.none? { |word| word.include?("git ") }
    engine.run_envs.last.slice("WWISE_TOKEN", "GH_TOKEN") == { "WWISE_TOKEN" => "t0k", "GH_TOKEN" => "gho_host" }

    Cleanup
    ENV.delete("WWISE_TOKEN")
    FileUtils.rm_rf(root)
  end

  test "run on a persisted image execs in its service container (here already up: the fake's inspect answers yes), never a one-shot run" do
    Given
    root = checkout_root
    engine = FakeContainerEngine.new
    check = typed_mock(Dev::EngineResourcesCheck)
    subject = containers(engine, root:, check:)

    When
    status = capture_stdout { subject.run(image(persist: true), argv: ["dev", "build", "x"], workspace: mounted(root)) }

    Then "one exec against the service, in the checkout, the command as its argv; no `docker run`"
    _ * check.check!
    status == 0
    exec = engine.runs.find { |verb, *_rest| verb == "exec" }
    exec.include?(Dev::BuildContainer.service_container_name(image.ref, root))
    exec.each_cons(2).include?(["-w", root.to_s])
    exec.last(3) == ["dev", "build", "x"]
    engine.runs.none? { |verb, *_rest| verb == "run" }

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "exec_in runs the command in the container the caller holds, in the checkout, the image's run_env riding in; no image step" do
    Given
    root = checkout_root
    engine = FakeContainerEngine.new(&->(args) { args.fetch(0) == "exec" ? 2 : true })
    ENV["WWISE_TOKEN"] = "t0k"

    When
    status = containers(engine, root:).exec_in(
      "dev-myapp-cold-1", image: image(run_env: { "WWISE_TOKEN" => "wwise/token" }), argv: ["dev", "deps", "install"], workspace: mounted(root),
    )

    Then
    status == 2
    engine.runs.size == 1
    engine.runs.first == ["exec", "-e", "WWISE_TOKEN", "-w", root.to_s, "dev-myapp-cold-1", "dev", "deps", "install"]
    engine.run_envs.first == { "WWISE_TOKEN" => "t0k" }

    Cleanup
    ENV.delete("WWISE_TOKEN")
    FileUtils.rm_rf(root)
  end

  test "a snapshot workspace is WorkspaceNotMountedError before anything reaches the engine: #{entry}" do
    Given "a runner's delivery"
    root = checkout_root
    engine = FakeContainerEngine.new
    snapshot = Dev::Lifecycle::Snapshot.new(sha: SHA, branch: Dev::Lifecycle::SnapshotBranch.mint(runner: "cellbound-3d"))
    workspace = Dev::Lifecycle::Workspace::Snapshot.new(snapshot)

    When
    run.call(containers(engine, root:), image, workspace)

    Then
    error = raises Dev::ProjectContainer::WorkspaceNotMountedError
    error.message.include?("snapshot 0123456789ab")
    error.message.include?("a runner's delivery")
    engine.runs.empty?

    Cleanup
    FileUtils.rm_rf(root)

    Where
    entry     | run
    "run"     | ->(subject, image, workspace) { subject.run(image, argv: ["true"], workspace:) }
    "exec_in" | ->(subject, image, workspace) { subject.exec_in("c", image:, argv: ["true"], workspace:) }
  end

  test "DEV_PUBLISH_IMAGE=1 asks the image step to publish; unset, it never pushes" do
    Given
    root = checkout_root
    ENV["DEV_PUBLISH_IMAGE"] = publish ? "1" : nil
    engine = FakeContainerEngine.new
    client = Dev::BuildContainer.new(engine:, host_os: "darwin")
    check = typed_mock(Dev::EngineResourcesCheck)
    subject = containers(engine, root:, client:, check:)

    When
    subject.run(image, argv: ["true"], workspace: mounted(root))

    Then
    _ * check.check!
    1 * client.ensure_environment_image!(anything, publish: expected) >> image.ref
    engine.runs.last.first == "run"

    Cleanup
    ENV.delete("DEV_PUBLISH_IMAGE")
    FileUtils.rm_rf(root)

    Where
    publish | expected
    true    | true
    false   | false
  end

  test "fetch is a no-op when the data root is shared (Linux): what the container wrote is already in the host's store" do
    Given
    root = checkout_root
    engine = FakeContainerEngine.new

    When
    containers(engine, root:, host_os: "linux").fetch(image, into: Pathname("/anywhere"))

    Then
    engine.runs.empty?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "fetch on a Mac copies out of a one-shot container of the image, into the host's data root, and removes the container after" do
    Given "a data root for this test"
    root = checkout_root
    data_root = Pathname(Dir.mktmpdir("project-container-"))
    original = ENV["DEV_DATA_ROOT"]
    ENV["DEV_DATA_ROOT"] = data_root.to_s
    into = data_root / "artifacts" / "myapp" / "win64"
    engine = FakeContainerEngine.new

    When
    capture_stdout { containers(engine, root:, host_os: "darwin").fetch(image, into:) }

    Then "the copy names the same path under the container's data root, and rm -f follows"
    copy = engine.runs.find { |verb, *_rest| verb == "cp" }
    copy[1].end_with?(":/var/lib/dev/artifacts/myapp/win64/.")
    copy[1].start_with?(Dev::BuildContainer.service_container_name(image.ref, root) + "-cold-")
    copy[2] == into.to_s
    engine.runs.last[0, 2] == ["rm", "-f"]
    into.directory?

    Cleanup
    ENV["DEV_DATA_ROOT"] = original
    FileUtils.rm_rf(data_root)
    FileUtils.rm_rf(root)
  end

  test "fetch into a path outside the host's data root is OutsideDataRootError before anything runs in a container" do
    Given
    root = checkout_root
    data_root = Pathname(Dir.mktmpdir("project-container-"))
    original = ENV["DEV_DATA_ROOT"]
    ENV["DEV_DATA_ROOT"] = (data_root / "data").to_s
    engine = FakeContainerEngine.new

    When
    capture_stdout { containers(engine, root:, host_os: "darwin").fetch(image, into: data_root / "elsewhere") }

    Then
    raises Dev::BuildContainer::OutsideDataRootError
    engine.runs.none? { |verb, *_rest| verb == "cp" }

    Cleanup
    ENV["DEV_DATA_ROOT"] = original
    FileUtils.rm_rf(data_root)
    FileUtils.rm_rf(root)
  end

  private

  # A checkout for one test: a real directory, since the mount makes the
  # shadowenv directories in it. Resolved, as the client resolves it.
  def checkout_root
    Pathname(File.realpath(Dir.mktmpdir("project-container-checkout-")))
  end

  def containers(engine, root:, token: nil, hint: nil, check: typed_mock(Dev::EngineResourcesCheck), host_os: "darwin",
    client: Dev::BuildContainer.new(engine:, host_os:))
    Dev::ProjectContainer.new(
      project_root: root, client:, engine_hint: hint, resources_check: check,
      github_token: Dev::ContainerGithubToken.new(source: -> { token }),
    )
  end

  def image(persist: false, run_env: {})
    Dev::EnvironmentImage.new(
      name: "myapp-linux", from: "ghcr.io/d3mlabs/unreal-engine-build-base", from_digest: "a" * 64,
      platform: "linux/amd64", apt: [], registry: "ghcr.io/d3mlabs", persist:, run_env:,
    )
  end

  # The tree as the container's transport delivers it: the checkout, mounted.
  def mounted(root)
    Dev::Lifecycle::Workspace::Mounted.new(root)
  end

  def capture_stdout
    previous = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = previous
  end
end

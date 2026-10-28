# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/build_container"
require "dev/build_container_config"
require "dev/engine_resources_check"
require "support/fake_container_engine"
require "support/fake_registry_login"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class BuildContainerTest < Minitest::Test
  include SorbetHelper

  # Engine-injected instance under test: the docker CLI is a true boundary,
  # so the fake engine records argv instead of tests stubbing Kernel#system.
  # A Mac unless said otherwise: the data root's shape is the host OS's,
  # and these tests run on either.
  def build_container(engine: FakeContainerEngine.new, host_os: "darwin", host_user: "jp")
    Dev::BuildContainer.new(engine: engine, host_os: host_os, host_user: host_user)
  end

  test "the Linuxbrew prefix volume is per host user on Linux and per VM on a Mac: one owner per prefix" do
    Expect
    Dev::BuildContainer.prefix_volume(host_os: "linux", host_user: "runner") == "dev-linuxbrew-runner"
    Dev::BuildContainer.prefix_volume(host_os: "linux", host_user: "jpduchesne") == "dev-linuxbrew-jpduchesne"
    Dev::BuildContainer.prefix_volume(host_os: "darwin", host_user: "jp") == "dev-linuxbrew"
    Dev::BuildContainer.prefix_volume(host_os: "linux") == "dev-linuxbrew-#{Dev::BuildContainer.host_user}"
    !Dev::BuildContainer.host_user.empty?
  end

  def service(name, running:)
    Dev::BuildContainer::ServiceContainer.new(name: name, running: running)
  end

  # A method, not a block: RSpock's source rewrite gives one-parameter
  # blocks a trailing comma, which splats an Array argument.
  def detached_run?(args)
    args.first(2) == ["run", "-d"]
  end

  test "content_tag produces deterministic hash from Dockerfile and lockfile" do
    Given "a project with Dockerfile and deps.lock"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    File.write(File.join(dir, "deps.lock"), "cmake: {version: 3.31}")

    When "computing the tag"
    tag = Dev::BuildContainer.content_tag(project_root: Pathname(dir))

    Then
    tag.start_with?("content-")
    tag.length == "content-".length + 12

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "content_tag changes when Dockerfile changes" do
    Given "a project with a Dockerfile"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    tag_a = Dev::BuildContainer.content_tag(project_root: Pathname(dir))

    When "the Dockerfile changes"
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:25.04")
    tag_b = Dev::BuildContainer.content_tag(project_root: Pathname(dir))

    Then
    tag_a != tag_b

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "content_tag is stable when files are unchanged" do
    Given "a project with a Dockerfile"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")

    When "computing twice"
    tag_a = Dev::BuildContainer.content_tag(project_root: Pathname(dir))
    tag_b = Dev::BuildContainer.content_tag(project_root: Pathname(dir))

    Then
    tag_a == tag_b

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "content_tag handles missing optional files gracefully" do
    Given "a project with only Dockerfile (no .dockerignore or lockfile)"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")

    When "computing the tag"
    tag = Dev::BuildContainer.content_tag(project_root: Pathname(dir))

    Then
    tag.start_with?("content-")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "image_with_tag refuses a config that names no image: that project's image is its lock's pin" do
    Given
    config = Dev::BuildContainerConfig.new(persist: true)

    When
    Dev::BuildContainer.image_with_tag(config, project_root: Pathname("/nowhere"))

    Then
    error = raises(Dev::BuildContainer::NoDockerfileImageError)
    error.message.include?("`image` pin")
  end

  test "image_with_tag combines config and content tag" do
    Given "a config and project"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")

    When "computing the full image reference"
    result = Dev::BuildContainer.image_with_tag(config, project_root: Pathname(dir))

    Then
    result.start_with?("jpduchesne89/snappy-linux:content-")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "docker_run_command produces correct command array" do
    When "building a docker run command"
    cmd = build_container.docker_run_command(
      "jpduchesne89/snappy:content-abc123",
      project_root: Pathname("/project"),
      shell_cmd: "./bin/build.sh",
    ).argv

    Then
    cmd[0] == "docker"
    cmd[1] == "run"
    cmd.include?("--rm")
    cmd.include?("-v")
    cmd.include?("/project:/project")
    cmd.last(3) == ["sh", "-c", "./bin/build.sh"]
  end

  test "docker_run_command widens the pending-signal ulimit (Rosetta pend_signal aborts)" do
    When "building a docker run command"
    cmd = build_container.docker_run_command(
      "jpduchesne89/snappy:content-abc123",
      project_root: Pathname("/project"),
      shell_cmd: "./bin/build.sh",
    ).argv

    Then "the run carries the widened sigpending bucket"
    cmd.include?("sigpending=1000000")
    cmd[cmd.index("sigpending=1000000") - 1] == "--ulimit"
  end

  test "docker_run_command renders extra volume mounts" do
    When "building a docker run command with volumes"
    cmd = build_container.docker_run_command(
      "jpduchesne89/snappy:content-abc123",
      project_root: Pathname("/project"),
      shell_cmd: "./bin/build.sh",
      volumes: ["/opt/engines/ue:/ue", "/var/cache/wwise:/wwise"],
    ).argv

    Then
    cmd.include?("/opt/engines/ue:/ue")
    cmd.include?("/var/cache/wwise:/wwise")
    cmd[cmd.index("/opt/engines/ue:/ue") - 1] == "-v"
    cmd[cmd.index("/var/cache/wwise:/wwise") - 1] == "-v"
    cmd.index("-w") > cmd.index("/var/cache/wwise:/wwise")
  end

  test "docker_run_command names env vars with bare -e flags and carries their values in the invocation's env, never on argv (dev#317)" do
    When "building a docker run command with env"
    invocation = build_container.docker_run_command(
      "jpduchesne89/snappy:content-abc123",
      project_root: Pathname("/project"),
      shell_cmd: "./bin/build.sh",
      env: { "WWISE_TOKEN" => "tok-123" },
    )
    cmd = invocation.argv

    Then "argv says -e WWISE_TOKEN (docker reads the value from the client's env) before -w; the value is in env only"
    cmd.each_cons(2).include?(["-e", "WWISE_TOKEN"])
    cmd.index("-w") > cmd.index("WWISE_TOKEN")
    cmd.none? { |part| part.include?("tok-123") }
    invocation.env["WWISE_TOKEN"] == "tok-123"
  end

  test "docker_run_command marks the container as inside so the dev it runs knows where it is" do
    When "building a one-shot run with its own env"
    invocation = build_container.docker_run_command(
      "jpduchesne89/snappy:content-abc123",
      project_root: Pathname("/project"),
      shell_cmd: "./bin/build.sh",
      env: { "WWISE_TOKEN" => "tok-123" },
    )
    cmd = invocation.argv

    Then "DEV_INSIDE_CONTAINER rides -e beside the configured env, before the image; both values in the env"
    cmd.each_cons(2).include?(["-e", "DEV_INSIDE_CONTAINER"])
    cmd.each_cons(2).include?(["-e", "WWISE_TOKEN"])
    cmd.index("DEV_INSIDE_CONTAINER") < cmd.index("jpduchesne89/snappy:content-abc123")
    invocation.env.slice("DEV_INSIDE_CONTAINER", "WWISE_TOKEN") == { "DEV_INSIDE_CONTAINER" => "1", "WWISE_TOKEN" => "tok-123" }
  end

  test "docker_run_command mounts the container's own data root volumes, never the host's directory (ADR-0008)" do
    Given "a host data root that must not leak into the container"
    root = Dir.mktmpdir("dev-data-root")
    original = ENV["DEV_DATA_ROOT"]
    ENV["DEV_DATA_ROOT"] = root
    engine = FakeContainerEngine.new

    When "building a one-shot run"
    invocation = build_container(engine: engine).docker_run_command(
      "jpduchesne89/snappy:content-abc123",
      project_root: Pathname("/project"),
      shell_cmd: "./bin/build.sh",
    )
    cmd = invocation.argv

    Then "both volumes are created first (docker volume create is idempotent), mounted at the data root and the Linuxbrew prefix before the image, DEV_DATA_ROOT names the mount, and the host's directory appears nowhere"
    engine.runs.include?(["volume", "create", "dev-data-root"])
    engine.runs.include?(["volume", "create", "dev-linuxbrew"])
    cmd.each_cons(2).include?(["-v", "dev-data-root:/var/lib/dev"])
    cmd.each_cons(2).include?(["-v", "dev-linuxbrew:/home/linuxbrew/.linuxbrew"])
    cmd.index("dev-data-root:/var/lib/dev") < cmd.index("jpduchesne89/snappy:content-abc123")
    cmd.each_cons(2).include?(["-e", "DEV_DATA_ROOT"])
    invocation.env["DEV_DATA_ROOT"] == "/var/lib/dev"
    cmd.none? { |part| part.include?(root) }
    invocation.env.values.none? { |value| value.include?(root) }

    Cleanup
    ENV["DEV_DATA_ROOT"] = original
    FileUtils.rm_rf(root)
  end

  test "on Linux, #{what} bind-mounts the host's data root at its own path — one store, both sides (dev#308)" do
    Given "a Linux host whose data root is #{root_kind}"
    root = Dir.mktmpdir("linux-data-root")
    original = ENV["DEV_DATA_ROOT"]
    ENV["DEV_DATA_ROOT"] = root
    engine = FakeContainerEngine.new
    bc = build_container(engine: engine, host_os: "linux")

    When
    cmd, env = if what == "docker_run_command"
      invocation = bc.docker_run_command("ghcr.io/d3mlabs/snappy-linux:abc", project_root: Pathname("/project"), shell_cmd: "./bin/build.sh")
      [invocation.argv, invocation.env]
    else
      bc.send(:create_service_container, "svc", "ghcr.io/d3mlabs/snappy-linux:abc", project_root: Pathname("/project"))
      index = engine.runs.index(&method(:detached_run?))
      [engine.runs.fetch(index), engine.run_envs.fetch(index)]
    end

    Then "the host's root at the host's path, DEV_DATA_ROOT agreeing; no data-root volume; Linuxbrew still a volume — the host user's own (brew is single-owner, and the engine is shared by the host's users)"
    cmd.each_cons(2).include?(["-v", "#{root}:#{root}"])
    cmd.each_cons(2).include?(["-e", "DEV_DATA_ROOT"])
    env["DEV_DATA_ROOT"] == root
    cmd.each_cons(2).include?(["-v", "dev-linuxbrew-jp:/home/linuxbrew/.linuxbrew"])
    cmd.none? { |part| part.include?("dev-data-root") }
    !engine.runs.include?(["volume", "create", "dev-data-root"])
    engine.runs.include?(["volume", "create", "dev-linuxbrew-jp"])
    cmd.count { |part| part == "-v" } == 3

    Cleanup
    ENV["DEV_DATA_ROOT"] = original
    FileUtils.rm_rf(root)

    Where
    what                       | root_kind
    "docker_run_command"       | "the override"
    "create_service_container" | "the override"
  end

  test "on Linux with the default root, the mount is /var/lib/dev on both sides" do
    Given
    original = ENV["DEV_DATA_ROOT"]
    ENV.delete("DEV_DATA_ROOT")
    Dev::Platform.stubs(:os).returns("linux")

    When
    invocation = build_container(host_os: "linux").docker_run_command(
      "ghcr.io/d3mlabs/snappy-linux:abc", project_root: Pathname("/project"), shell_cmd: "./bin/build.sh",
    )

    Then
    invocation.argv.each_cons(2).include?(["-v", "/var/lib/dev:/var/lib/dev"])
    invocation.argv.each_cons(2).include?(["-e", "DEV_DATA_ROOT"])
    invocation.env["DEV_DATA_ROOT"] == "/var/lib/dev"

    Cleanup
    ENV["DEV_DATA_ROOT"] = original if original
  end

  test "docker_run_command expands ~ in volume host paths, re-rooting ~/.dev onto the data root" do
    Given "a scratch data root"
    root = Dir.mktmpdir("bc-data-root-")
    original = ENV["DEV_DATA_ROOT"]
    ENV["DEV_DATA_ROOT"] = root

    When "building a docker run command with a ~ volume"
    cmd = build_container.docker_run_command(
      "jpduchesne89/snappy:content-abc123",
      project_root: Pathname("/project"),
      shell_cmd: "./bin/build.sh",
      volumes: ["~/.dev/engines/unreal-engine-css:/ue"],
    ).argv

    Then
    cmd.include?("#{File.join(root, "engines/unreal-engine-css")}:/ue")
    !cmd.any? { |part| part.start_with?("~") }

    Cleanup
    ENV["DEV_DATA_ROOT"] = original
    FileUtils.rm_rf(root)
  end

  test "docker_run_command carries the engine's argv prefix" do
    Given "an engine whose docker rides a custom prefix"
    engine = FakeContainerEngine.new
    engine.instance_variable_set(:@argv_prefix, ["docker", "--context", "remote"])

    When "building a docker run command"
    cmd = build_container(engine: engine).docker_run_command(
      "img:tag", project_root: Pathname("/project"), shell_cmd: "true",
    ).argv

    Then "the prefix leads the argv"
    cmd[0, 3] == ["docker", "--context", "remote"]
    cmd[3] == "run"
  end

  test "mount composition refuses an engine without local mounts (the remote-poisoned assumption, named)" do
    Given "an engine whose daemon cannot see local paths"
    bc = build_container(engine: FakeContainerEngine.new(local_mounts: false))

    When "composing a run command (which always mounts the project)"
    bc.docker_run_command("img:tag", project_root: Pathname("/project"), shell_cmd: "true")

    Then
    raises Dev::BuildContainer::LocalMountsUnsupportedError
  end

  test "ensure_image! gates on the engine's resources before touching any image" do
    Given "an engine hint and a check that finds the engine short"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    resources = Dev::EngineResources::Hint.new(cpus: 12, memory_gib: 24)
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")
    engine = FakeContainerEngine.new
    check = typed_mock(Dev::EngineResourcesCheck)
    check.expects(:check!).once.with(engine: engine, hint: resources)
      .raises(Dev::EngineResourcesCheck::UndersizedEngineError, "4 cpus")
    bc = Dev::BuildContainer.new(engine: engine, resources_check: check)

    When "ensuring the image"
    bc.ensure_image!(config, project_root: Pathname(dir), resources: resources)

    Then "the refusal is the outcome; no docker call was made"
    raises Dev::EngineResourcesCheck::UndersizedEngineError
    engine.runs.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure_image! hands the config's (possibly absent) hint to the check every time" do
    Given "a config without a hint and a pull hit"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")
    engine = FakeContainerEngine.new
    check = typed_mock(Dev::EngineResourcesCheck)
    check.expects(:check!).once.with(engine: engine, hint: nil)
    bc = Dev::BuildContainer.new(engine: engine, resources_check: check)
    bc.stubs(:local_image?).returns(false)
    bc.stubs(:pull).returns(true)

    When "ensuring the image"
    result = bc.ensure_image!(config, project_root: Pathname(dir))

    Then
    result.start_with?("jpduchesne89/snappy-linux:content-")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure_image! returns existing image on pull hit" do
    Given "a project and config where pull succeeds"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")
    bc = build_container

    When "ensuring the image"
    bc.stubs(:local_image?).returns(false)
    bc.stubs(:pull).returns(true)
    result = bc.ensure_image!(config, project_root: Pathname(dir))

    Then
    result.start_with?("jpduchesne89/snappy-linux:content-")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure_image! resolves build args lazily and only on cache miss" do
    Given "a project whose image must be built"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")
    provider_calls = 0
    received_args = nil
    bc = build_container

    When "ensuring the image with a build args provider"
    bc.stubs(:local_image?).returns(false)
    bc.stubs(:pull).returns(false)
    bc.stubs(:build!).with { |_tag, build_args:, **_|
      received_args = build_args
      true }
    bc.stubs(:push!).returns(true)
    bc.ensure_image!(
      config,
      project_root: Pathname(dir),
      build_args_provider: -> {
                             provider_calls += 1
                             { "WWISE_EMAIL" => "me@example.com" } },
    )

    Then
    provider_calls == 1
    received_args == { "WWISE_EMAIL" => "me@example.com" }

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure_image! does not invoke the build args provider on cache hit" do
    Given "a project whose image pulls successfully"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")
    provider_calls = 0
    bc = build_container

    When "ensuring the image"
    bc.stubs(:local_image?).returns(false)
    bc.stubs(:pull).returns(true)
    bc.ensure_image!(
      config,
      project_root: Pathname(dir),
      build_args_provider: -> {
                             provider_calls += 1
                             {} },
    )

    Then
    provider_calls == 0

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "build! passes build args as --build-arg flags" do
    Given "a project root and a recording engine"
    dir = Dir.mktmpdir("build-container-test-")
    engine = FakeContainerEngine.new

    When "building with build args"
    build_container(engine: engine).build!(
      "img:tag",
      project_root: Pathname(dir),
      build_args: { "WWISE_EMAIL" => "me@example.com", "WWISE_PASSWORD" => "hunter2" },
    )

    Then
    engine.runs.last.include?("--build-arg")
    engine.runs.last.include?("WWISE_EMAIL=me@example.com")
    engine.runs.last.include?("WWISE_PASSWORD=hunter2")
    engine.runs.last.last == dir

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "build! uses plain BuildKit progress so CI logs stream every step" do
    Given "a project root and a recording engine"
    dir = Dir.mktmpdir("build-container-test-")
    engine = FakeContainerEngine.new

    When "building"
    build_container(engine: engine).build!("img:tag", project_root: Pathname(dir))

    Then "the non-TTY-silent auto renderer is overridden"
    engine.runs.last.include?("--progress=plain")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure_image! prefers a local image over pulling or building" do
    Given "a project whose image already exists locally"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")
    pulled = []
    bc = build_container

    When "ensuring the image"
    bc.stubs(:local_image?).returns(true)
    bc.stubs(:pull).with { |tag|
      pulled << tag
      true }
    result = bc.ensure_image!(config, project_root: Pathname(dir))

    Then
    result.start_with?("jpduchesne89/snappy-linux:content-")
    pulled.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure_image! builds and pushes on pull miss" do
    Given "a project where pull fails"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")
    built = []
    pushed = []
    bc = build_container

    When "ensuring the image"
    bc.stubs(:local_image?).returns(false)
    bc.stubs(:pull).returns(false)
    bc.stubs(:build!).with { |tag, **_|
      built << tag
      true }
    bc.stubs(:push!).with { |tag|
      pushed << tag
      true }
    result = bc.ensure_image!(config, project_root: Pathname(dir))

    Then
    result.start_with?("jpduchesne89/snappy-linux:content-")
    built.size == 1
    pushed.size == 1
    built[0] == result

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure_image! skips push when push: false" do
    Given "a project where push is disabled"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")
    pushed = []
    bc = build_container

    When "ensuring the image with push: false"
    bc.stubs(:local_image?).returns(false)
    bc.stubs(:pull).returns(false)
    bc.stubs(:build!).returns(true)
    bc.stubs(:push!).with { |tag|
      pushed << tag
      true }
    bc.ensure_image!(config, project_root: Pathname(dir), push: false)

    Then
    pushed.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure_image! publishes a locally-resolved image when publish is requested" do
    Given "an image present locally but absent from the registry"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")
    tag = Dev::BuildContainer.image_with_tag(config, project_root: Pathname(dir))
    bc = build_container

    When "ensuring the image with publish: true"
    result = bc.ensure_image!(config, project_root: Pathname(dir), publish: true)

    Then "the local image is honored, then published to the registry (no pull, no build)"
    result == tag
    1 * bc.local_image?(tag) >> true
    0 * bc.pull(tag)
    1 * bc.registry_has?(tag) >> false
    1 * bc.push!(tag) >> true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure_image! does not re-push a locally-resolved image already in the registry" do
    Given "an image present locally and already advertised by the registry"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")
    tag = Dev::BuildContainer.image_with_tag(config, project_root: Pathname(dir))
    bc = build_container

    When "ensuring the image with publish: true"
    result = bc.ensure_image!(config, project_root: Pathname(dir), publish: true)

    Then "the registry check short-circuits the push"
    result == tag
    1 * bc.local_image?(tag) >> true
    1 * bc.registry_has?(tag) >> true
    0 * bc.push!(tag)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure_image! when publishing asks the registry before pulling: a hit pulls nothing, builds nothing" do
    Given "a publisher with no local image and a registry that already advertises the tag"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")
    tag = Dev::BuildContainer.image_with_tag(config, project_root: Pathname(dir))
    bc = build_container
    bc.stubs(:local_image?).returns(false)

    When "ensuring the image with publish on"
    result = bc.ensure_image!(config, project_root: Pathname(dir), publish: true)

    Then "the manifest lookup is the whole cost"
    result == tag
    1 * bc.registry_has?(tag) >> true
    0 * bc.pull(tag)
    0 * bc.push!(tag)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure_image! when publishing falls through to pull and build on a registry miss" do
    Given "a publisher with no local image, a registry miss and a pull miss"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")
    tag = Dev::BuildContainer.image_with_tag(config, project_root: Pathname(dir))
    bc = build_container
    bc.stubs(:local_image?).returns(false)
    bc.stubs(:registry_has?).returns(false)
    built = []
    bc.stubs(:build!).with { |built_tag, **_|
      built << built_tag
      true }

    When "ensuring the image with publish on"
    result = bc.ensure_image!(config, project_root: Pathname(dir), publish: true)

    Then "it builds and pushes, without asking the registry a second time"
    result == tag
    built == [tag]
    1 * bc.pull(tag) >> false
    1 * bc.push!(tag) >> true
    0 * bc.publish!(tag)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure_image! without publish never consults the registry" do
    Given "a plain host with no local image"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")
    tag = Dev::BuildContainer.image_with_tag(config, project_root: Pathname(dir))
    bc = build_container
    bc.stubs(:local_image?).returns(false)

    When "ensuring the image"
    result = bc.ensure_image!(config, project_root: Pathname(dir))

    Then "it goes straight to pull"
    result == tag
    0 * bc.registry_has?(tag)
    1 * bc.pull(tag) >> true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure_image! does not publish a local hit by default" do
    Given "an image present locally and publish left at its default"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")
    tag = Dev::BuildContainer.image_with_tag(config, project_root: Pathname(dir))
    bc = build_container

    When "ensuring the image"
    result = bc.ensure_image!(config, project_root: Pathname(dir))

    Then "no registry interaction happens — a plain local run never publishes"
    result == tag
    1 * bc.local_image?(tag) >> true
    0 * bc.registry_has?(tag)
    0 * bc.push!(tag)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure_image! publishes a freshly built image when publish is requested" do
    Given "a project that misses both caches and is provisioned with publish"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")
    tag = Dev::BuildContainer.image_with_tag(config, project_root: Pathname(dir))
    bc = build_container

    When "ensuring the image with push: false (the only real caller) and publish: true"
    result = bc.ensure_image!(config, project_root: Pathname(dir), push: false, publish: true)

    Then "it asks the registry once, builds, and pushes without asking again"
    result == tag
    1 * bc.local_image?(tag) >> false
    1 * bc.registry_has?(tag) >> false
    1 * bc.pull(tag) >> false
    1 * bc.build!(tag, project_root: Pathname(dir), build_args: {}, secrets: {}) >> true
    1 * bc.push!(tag) >> true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "publish! is a no-op when the registry already advertises the tag" do
    Given "the instance under test"
    bc = build_container

    When "publishing a tag the registry already has"
    result = bc.publish!("img:tag")

    Then "the manifest check short-circuits and nothing is pushed"
    result == true
    1 * bc.registry_has?("img:tag") >> true
    0 * bc.push!("img:tag")
  end

  test "publish! pushes when the registry lacks the tag" do
    Given "the instance under test"
    bc = build_container

    When "publishing a tag the registry lacks"
    result = bc.publish!("img:tag")

    Then "it pushes the local image"
    result == true
    1 * bc.registry_has?("img:tag") >> false
    1 * bc.push!("img:tag") >> true
  end

  test "publish! warns but does not raise when the push fails" do
    Given "the instance under test"
    bc = build_container

    When "the registry lacks the tag and the push fails"
    result = bc.publish!("img:tag")

    Then "the failure is surfaced as a falsey return, not an exception"
    result == false
    1 * bc.registry_has?("img:tag") >> false
    1 * bc.push!("img:tag") >> false
  end

  test "build! raises when docker build fails" do
    Given "a project root and an engine whose builds fail"
    dir = Dir.mktmpdir("build-container-test-")
    engine = FakeContainerEngine.new { |_args| false }

    When "docker build fails"
    build_container(engine: engine).build!("bad:tag", project_root: Pathname(dir))

    Then
    raises RuntimeError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "content_tag includes .dockerignore in hash" do
    Given "a project with Dockerfile and .dockerignore"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    tag_without = Dev::BuildContainer.content_tag(project_root: Pathname(dir))

    When "adding a .dockerignore"
    File.write(File.join(dir, ".dockerignore"), "node_modules")
    tag_with = Dev::BuildContainer.content_tag(project_root: Pathname(dir))

    Then
    tag_without != tag_with

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "content_tag includes deps.lock in hash" do
    Given "a project with a Dockerfile"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    tag_without = Dev::BuildContainer.content_tag(project_root: Pathname(dir))

    When "adding a deps.lock"
    File.write(File.join(dir, "deps.lock"), "SML: {version: 3.12.0}")
    tag_with = Dev::BuildContainer.content_tag(project_root: Pathname(dir))

    Then
    tag_without != tag_with

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "content_tag changes when an extra_globs file changes" do
    Given "a project with a Dockerfile and a globbed Build.cs"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    FileUtils.mkdir_p(File.join(dir, "Mods/Snappy/Source/Snappy"))
    build_cs = File.join(dir, "Mods/Snappy/Source/Snappy/Snappy.Build.cs")
    File.write(build_cs, "// deps: Core")
    globs = ["Mods/*/Source/*/*.Build.cs"]
    tag_a = Dev::BuildContainer.content_tag(project_root: Pathname(dir), extra_globs: globs)

    When "the Build.cs changes"
    File.write(build_cs, "// deps: Core, SML")
    tag_b = Dev::BuildContainer.content_tag(project_root: Pathname(dir), extra_globs: globs)

    Then
    tag_a != tag_b

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "content_tag skips directories matched by a recursive extra_globs pattern" do
    Given "a project whose extra_globs recursive pattern matches a subdirectory"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    FileUtils.mkdir_p(File.join(dir, "bin/image/lib"))
    File.write(File.join(dir, "bin/image/build.sh"), "echo build")
    File.write(File.join(dir, "bin/image/lib/env.sh"), "echo env")
    globs = ["bin/image/**/*"]

    When "computing the content tag (the glob also matches bin/image/lib)"
    # Regression: the dir entry must be skipped, not read (Errno::EISDIR).
    tag_a = Dev::BuildContainer.content_tag(project_root: Pathname(dir), extra_globs: globs)
    File.write(File.join(dir, "bin/image/lib/env.sh"), "echo env changed")
    tag_b = Dev::BuildContainer.content_tag(project_root: Pathname(dir), extra_globs: globs)

    Then "it hashes the nested files without raising, and tracks their contents"
    tag_a.start_with?("content-")
    tag_a != tag_b

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "content_tag is unaffected by files outside extra_globs" do
    Given "a project with a Dockerfile and an unhashed .cpp"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    FileUtils.mkdir_p(File.join(dir, "Mods/Snappy/Source/Snappy"))
    File.write(File.join(dir, "Mods/Snappy/Source/Snappy/Snappy.Build.cs"), "// deps")
    globs = ["Mods/*/Source/*/*.Build.cs"]
    tag_a = Dev::BuildContainer.content_tag(project_root: Pathname(dir), extra_globs: globs)

    When "a non-globbed source file changes"
    File.write(File.join(dir, "Mods/Snappy/Source/Snappy/Snappy.cpp"), "int main() {}")
    tag_b = Dev::BuildContainer.content_tag(project_root: Pathname(dir), extra_globs: globs)

    Then
    tag_a == tag_b

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "content_tag is unaffected by a structure_globs file's content change" do
    Given "a project whose Build.cs is hashed as structure (paths only)"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    FileUtils.mkdir_p(File.join(dir, "Mods/Snappy/Source/Snappy"))
    build_cs = File.join(dir, "Mods/Snappy/Source/Snappy/Snappy.Build.cs")
    File.write(build_cs, "// deps: Core")
    globs = ["Mods/*/Source/*/*.Build.cs"]
    tag_a = Dev::BuildContainer.content_tag(project_root: Pathname(dir), structure_globs: globs)

    When "the Build.cs contents change but the module set does not"
    File.write(build_cs, "// deps: Core, UMG, Slate, AssetRegistry")
    tag_b = Dev::BuildContainer.content_tag(project_root: Pathname(dir), structure_globs: globs)

    Then "the tag is unchanged: a dependency edit must not invalidate the image"
    tag_a == tag_b

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "content_tag changes when a structure_globs path is added" do
    Given "a project with one module's Build.cs hashed as structure"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    FileUtils.mkdir_p(File.join(dir, "Mods/Snappy/Source/Snappy"))
    File.write(File.join(dir, "Mods/Snappy/Source/Snappy/Snappy.Build.cs"), "// deps")
    globs = ["Mods/*/Source/*/*.Build.cs"]
    tag_a = Dev::BuildContainer.content_tag(project_root: Pathname(dir), structure_globs: globs)

    When "a second module is added (a new Build.cs path)"
    FileUtils.mkdir_p(File.join(dir, "Mods/Snappy/Source/SnappyTests"))
    File.write(File.join(dir, "Mods/Snappy/Source/SnappyTests/SnappyTests.Build.cs"), "// deps")
    tag_b = Dev::BuildContainer.content_tag(project_root: Pathname(dir), structure_globs: globs)

    Then "the tag changes: adding/removing a module must invalidate the image"
    tag_a != tag_b

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "content_tag changes when a structure_globs path is removed" do
    Given "a project with two modules' Build.cs hashed as structure"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    FileUtils.mkdir_p(File.join(dir, "Mods/Snappy/Source/Snappy"))
    FileUtils.mkdir_p(File.join(dir, "Mods/Snappy/Source/SnappyTests"))
    File.write(File.join(dir, "Mods/Snappy/Source/Snappy/Snappy.Build.cs"), "// deps")
    tests_cs = File.join(dir, "Mods/Snappy/Source/SnappyTests/SnappyTests.Build.cs")
    File.write(tests_cs, "// deps")
    globs = ["Mods/*/Source/*/*.Build.cs"]
    tag_a = Dev::BuildContainer.content_tag(project_root: Pathname(dir), structure_globs: globs)

    When "a module is removed (its Build.cs path disappears)"
    File.delete(tests_cs)
    tag_b = Dev::BuildContainer.content_tag(project_root: Pathname(dir), structure_globs: globs)

    Then
    tag_a != tag_b

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "image_with_tag honors config.structure_globs" do
    Given "two configs differing only by a structural module path"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    FileUtils.mkdir_p(File.join(dir, "Mods/Snappy/Source/Snappy"))
    File.write(File.join(dir, "Mods/Snappy/Source/Snappy/Snappy.Build.cs"), "// deps")
    structure = ["Mods/*/Source/*/*.Build.cs"]
    config = Dev::BuildContainerConfig.new(
      image: "snappy-linux", registry: "jpduchesne89", structure_globs: structure,
    )
    ref_a = Dev::BuildContainer.image_with_tag(config, project_root: Pathname(dir))

    When "a module is added"
    FileUtils.mkdir_p(File.join(dir, "Mods/Snappy/Source/SnappyTests"))
    File.write(File.join(dir, "Mods/Snappy/Source/SnappyTests/SnappyTests.Build.cs"), "// deps")
    ref_b = Dev::BuildContainer.image_with_tag(config, project_root: Pathname(dir))

    Then "the full image reference changes via the structural path set"
    ref_a != ref_b
    ref_a.start_with?("jpduchesne89/snappy-linux:content-")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "build! passes secrets with BuildKit enabled and nothing from the data root" do
    Given "a project root and a recording engine"
    dir = Dir.mktmpdir("build-container-test-")
    engine = FakeContainerEngine.new

    When "building with secrets"
    build_container(engine: engine).build!(
      "img:tag",
      project_root: Pathname(dir),
      secrets: { "WWISE_TOKEN" => "tok-123" },
    )

    Then "BuildKit env and the secret flag are present; no build context names a host tree"
    engine.run_envs.last["DOCKER_BUILDKIT"] == "1"
    engine.run_envs.last["WWISE_TOKEN"] == "tok-123"
    !engine.runs.last.include?("--build-context")
    engine.runs.last.include?("--secret")
    engine.runs.last.include?("id=WWISE_TOKEN,env=WWISE_TOKEN")
    engine.runs.last.last == dir
  end

  test "build! keeps the secret value off argv" do
    Given "a project root and a recording engine"
    dir = Dir.mktmpdir("build-container-test-")
    engine = FakeContainerEngine.new

    When "building with a secret"
    build_container(engine: engine).build!(
      "img:tag",
      project_root: Pathname(dir),
      secrets: { "WWISE_TOKEN" => "super-secret" },
    )

    Then "the value travels via env, never as an argument"
    engine.runs.last.none? { |part| part.include?("super-secret") }

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure_image! resolves secrets lazily on cache miss" do
    Given "a project whose image must be built"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")
    secret_calls = 0
    received_secrets = nil
    bc = build_container

    When "ensuring the image with a secrets provider"
    bc.stubs(:local_image?).returns(false)
    bc.stubs(:pull).returns(false)
    bc.stubs(:build!).with do |_tag, secrets:, **_|
      received_secrets = secrets
      true
    end
    bc.stubs(:push!).returns(true)
    bc.ensure_image!(
      config,
      project_root: Pathname(dir),
      build_args_provider: -> { {} },
      secrets_provider: -> {
                          secret_calls += 1
                          { "WWISE_TOKEN" => "tok" } },
    )

    Then
    secret_calls == 1
    received_secrets == { "WWISE_TOKEN" => "tok" }

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure_image! does not invoke the secrets provider on cache hit" do
    Given "a project whose image pulls successfully"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")
    secret_calls = 0
    bc = build_container

    When "ensuring the image"
    bc.stubs(:local_image?).returns(false)
    bc.stubs(:pull).returns(true)
    bc.ensure_image!(
      config,
      project_root: Pathname(dir),
      secrets_provider: -> {
                          secret_calls += 1
                          {} },
    )

    Then
    secret_calls == 0

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure_image! builds a base then runs+commits when prewarm is set" do
    Given "a project whose image must be built and declares a prewarm command"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    config = Dev::BuildContainerConfig.new(
      image: "snappy-linux", registry: "jpduchesne89",
      volumes: ["/engines/ue:/ue"], prewarm: "bash /work/bin/prewarm.sh",
    )
    tag = Dev::BuildContainer.image_with_tag(config, project_root: Pathname(dir))
    bc = build_container

    When "ensuring the image"
    result = bc.ensure_image!(config, project_root: Pathname(dir))

    Then "the base is built engine-free, the prewarm runs against it, and the base tag is dropped"
    result == tag
    1 * bc.local_image?(tag) >> false
    1 * bc.pull(tag) >> false
    1 * bc.build!("#{tag}-base", project_root: Pathname(dir), build_args: {}, secrets: {}) >> true
    1 * bc.prewarm_commit!("#{tag}-base", tag, volumes: ["/engines/ue:/ue"],
      prewarm: "bash /work/bin/prewarm.sh", secrets: {}) >> true
    1 * bc.remove_image("#{tag}-base") >> true
    1 * bc.push!(tag) >> true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "prewarm_commit! runs the prewarm with dep volumes and secret files, commits, and cleans up" do
    Given "resolved dep volumes, a secret, and a recording engine"
    engine = FakeContainerEngine.new
    bc = build_container(engine: engine)

    When "running the prewarm commit"
    bc.prewarm_commit!(
      "img:tag-base", "img:tag",
      volumes: ["/engines/ue:/ue"], prewarm: "bash /work/bin/prewarm.sh", secrets: { "WWISE_TOKEN" => "tok" }
    )

    Then "the run mounts the engine + secret file (never -e: commit would bake env), runs under the watcher, commits, and removes it"
    1 * bc.prewarm_container_name >> "dev-prewarm-test"
    1 * bc.write_secret_files({ "WWISE_TOKEN" => "tok" }) >> { "WWISE_TOKEN" => "/tmp/dev-secret-xyz" }
    1 * bc.run_watched(["docker", "run", "--name", "dev-prewarm-test",
      "--ulimit", "sigpending=1000000",
      "-v", "/engines/ue:/ue",
      "-v", "/tmp/dev-secret-xyz:/run/secrets/WWISE_TOKEN:ro",
      "img:tag-base", "sh", "-c", "bash /work/bin/prewarm.sh"], container: "dev-prewarm-test") >> true
    engine.runs == [["commit", "dev-prewarm-test", "img:tag"], ["rm", "-f", "dev-prewarm-test"]]
  end

  test "prewarm_commit! raises when the prewarm run fails, still removing the container" do
    Given "a prewarm command that fails and a recording engine"
    engine = FakeContainerEngine.new
    bc = build_container(engine: engine)

    When "running the prewarm commit"
    bc.prewarm_commit!("img:tag-base", "img:tag", volumes: [], prewarm: "false", secrets: {})

    Then "it surfaces the failure and the ensure block removes the container (no commit)"
    raises RuntimeError
    1 * bc.prewarm_container_name >> "dev-prewarm-test"
    1 * bc.write_secret_files({}) >> {}
    1 * bc.run_watched(["docker", "run", "--name", "dev-prewarm-test",
      "--ulimit", "sigpending=1000000",
      "img:tag-base", "sh", "-c", "false"], container: "dev-prewarm-test") >> false
    engine.runs == [["rm", "-f", "dev-prewarm-test"]]
  end

  test "write_secret_files writes each secret to a private temp file" do
    Given "a scratch data root"
    root = Dir.mktmpdir("bc-data-root-")
    original = ENV["DEV_DATA_ROOT"]
    ENV["DEV_DATA_ROOT"] = root

    When "writing secret files"
    files = build_container.write_secret_files({ "TOK" => "s3cr3t" })

    Then "the value is on disk with owner-only permissions"
    File.read(files["TOK"]) == "s3cr3t"
    (File.stat(files["TOK"]).mode & 0o777) == 0o600

    Cleanup
    ENV["DEV_DATA_ROOT"] = original
    FileUtils.rm_rf(root)
  end

  test "write_secret_files places files in a private per-uid dir under the data root, never Dir.tmpdir" do
    Given "a scratch data root"
    # macOS + colima: the VM shares $HOME and /Users/Shared, NOT /var/folders
    # (Dir.tmpdir). A bind mount from an unshared path silently mounts an empty
    # directory, so the prewarm reads an empty secret and fails downstream.
    root = Dir.mktmpdir("bc-data-root-")
    original = ENV["DEV_DATA_ROOT"]
    ENV["DEV_DATA_ROOT"] = root

    When "writing secret files"
    files = build_container.write_secret_files({ "TOK" => "s3cr3t" })

    Then "each file lives in secrets-<uid>, a real dir owned by us, mode 0700"
    dir = File.join(root, "secrets-#{Process.uid}")
    files.values.all? { |p| File.dirname(p) == dir }
    st = File.lstat(dir)
    st.directory? == true
    st.uid == Process.uid
    (st.mode & 0o7777) == 0o700

    Cleanup
    ENV["DEV_DATA_ROOT"] = original
    FileUtils.rm_rf(root)
  end

  test "write_secret_files refuses a symlinked secrets dir (planted redirect)" do
    Given "an attacker-planted symlink where the per-uid dir belongs"
    # The data root's parent (/Users/Shared) ships world-writable on macOS: on
    # an unprovisioned machine any local user can pre-own the tree and plant a
    # symlink so our 0600 files land in a directory they control.
    root = Dir.mktmpdir("bc-data-root-")
    original = ENV["DEV_DATA_ROOT"]
    ENV["DEV_DATA_ROOT"] = root
    elsewhere = File.join(root, "attacker-controlled")
    FileUtils.mkdir_p(elsewhere)
    File.symlink(elsewhere, File.join(root, "secrets-#{Process.uid}"))

    When "writing secret files"
    build_container.write_secret_files({ "TOK" => "s3cr3t" })

    Then "the planted dir is refused, not used"
    raises Dev::BuildContainer::SecretDirCompromisedError

    Cleanup
    ENV["DEV_DATA_ROOT"] = original
    FileUtils.rm_rf(root)
  end

  test "write_secret_files refuses a secrets dir owned by another user" do
    Given "a per-uid dir whose owner is not us"
    root = Dir.mktmpdir("bc-data-root-")
    original = ENV["DEV_DATA_ROOT"]
    ENV["DEV_DATA_ROOT"] = root
    dir = File.join(root, "secrets-#{Process.uid}")
    FileUtils.mkdir_p(dir)
    foreign = stub(directory?: true, uid: Process.uid + 1, mode: 0o40700)
    File.stubs(:lstat).with(dir).returns(foreign)

    When "writing secret files"
    build_container.write_secret_files({ "TOK" => "s3cr3t" })

    Then "the foreign dir is refused — its owner could swap files under us"
    raises Dev::BuildContainer::SecretDirCompromisedError

    Cleanup
    File.unstub(:lstat)
    ENV["DEV_DATA_ROOT"] = original
    FileUtils.rm_rf(root)
  end

  test "write_secret_files sweeps stale secret files a killed run left behind" do
    Given "a leftover secret file from a SIGKILLed run, and a fresh one"
    # The ensure-block deletion covers normal failures, but SIGKILL leaves 0600
    # files under the data root, which macOS never purges (unlike /var/folders).
    root = Dir.mktmpdir("bc-data-root-")
    original = ENV["DEV_DATA_ROOT"]
    ENV["DEV_DATA_ROOT"] = root
    dir = File.join(root, "secrets-#{Process.uid}")
    FileUtils.mkdir_p(dir)
    FileUtils.chmod(0o700, dir)
    stale = File.join(dir, "dev-secret-stale")
    fresh = File.join(dir, "dev-secret-fresh")
    File.write(stale, "old")
    File.write(fresh, "new")
    File.utime(Time.now - 172_800, Time.now - 172_800, stale)

    When "writing secret files"
    files = build_container.write_secret_files({ "TOK" => "s3cr3t" })

    Then "the day-old file is gone; the recent one (a concurrent run's) survives"
    !File.exist?(stale)
    File.exist?(fresh)
    File.read(files["TOK"]) == "s3cr3t"

    Cleanup
    ENV["DEV_DATA_ROOT"] = original
    FileUtils.rm_rf(root)
  end

  test "service_container_name keys the name by image, workspace, and tag" do
    Given "a full image:tag and the checkout it runs in"
    root = Pathname("/work/snappy")
    wid = Dev::BuildContainer.workspace_id(root)

    When "naming the service container"
    name = Dev::BuildContainer.service_container_name("jpduchesne89/snappy-linux:content-abc123", root)

    Then "the name is registry-free, colon-free, dev-prefixed, and workspace-keyed"
    name == "dev-snappy-linux-#{wid}-content-abc123"
  end

  test "service_container_name differs per checkout for the same image tag" do
    Given "one image:tag checked out in two directories"
    tag = "jpduchesne89/snappy-linux:content-abc123"

    When "naming the service container for each checkout"
    runner = Dev::BuildContainer.service_container_name(tag, Pathname("/runner/_work/snappy/snappy"))
    manual = Dev::BuildContainer.service_container_name(tag, Pathname("/home/dev/snappy"))

    Then "the names differ, so neither checkout can hijack the other's container"
    runner != manual
  end

  test "docker_exec_command targets the container with /project workdir" do
    When "building a docker exec command"
    cmd = build_container.docker_exec_command(
      "dev-snappy-linux-content-abc", shell_cmd: "./bin/build.sh",
    ).argv

    Then
    cmd[0] == "docker"
    cmd[1] == "exec"
    cmd.include?("-w")
    cmd.include?("/project")
    cmd.include?("dev-snappy-linux-content-abc")
    cmd.last(3) == ["sh", "-c", "./bin/build.sh"]
  end

  test "docker_exec_command names env vars with bare -e flags before the container; the values ride the invocation's env, never argv (dev#317)" do
    When "building a docker exec command with env"
    invocation = build_container.docker_exec_command(
      "dev-snappy-linux-content-abc", shell_cmd: "./bin/build.sh",
      env: { "WWISE_TOKEN" => "tok-123" },
    )
    cmd = invocation.argv

    Then "the -e flag precedes the container name (a docker exec arg-order rule); the value is in env only"
    cmd.each_cons(2).include?(["-e", "WWISE_TOKEN"])
    cmd.index("WWISE_TOKEN") < cmd.index("dev-snappy-linux-content-abc")
    cmd.none? { |part| part.include?("tok-123") }
    invocation.env == { "WWISE_TOKEN" => "tok-123" }
  end

  test "ensure_service! creates the container when none exists" do
    Given "an image tag whose container is absent, and the checkout it runs in"
    tag = "jpduchesne89/snappy-linux:content-abc"
    root = Pathname("/proj")
    name = Dev::BuildContainer.service_container_name(tag, root)
    bc = build_container

    When "ensuring the service"
    result = bc.ensure_service!(tag, project_root: root, volumes: ["/e:/e"])

    Then "stale containers are reaped, then the container is created (never started)"
    result == name
    1 * bc.reap_stale_services!(tag, root) >> nil
    1 * bc.container_exists?(name) >> false
    1 * bc.create_service_container(name, tag,
      project_root: root, volumes: ["/e:/e"]) >> true
    0 * bc.start_container(name)
  end

  test "ensure_service! starts the container when it exists but is stopped" do
    Given "an image tag whose container exists but is stopped"
    tag = "jpduchesne89/snappy-linux:content-abc"
    root = Pathname("/proj")
    name = Dev::BuildContainer.service_container_name(tag, root)
    bc = build_container

    When "ensuring the service"
    bc.ensure_service!(tag, project_root: root)

    Then "the existing container is started, not recreated"
    1 * bc.reap_stale_services!(tag, root) >> nil
    1 * bc.container_exists?(name) >> true
    1 * bc.container_running?(name) >> false
    1 * bc.start_container(name) >> true
    0 * bc.create_service_container(name, tag,
      project_root: root, volumes: [])
  end

  test "ensure_service! is a no-op when the container is already running" do
    Given "an image tag whose container is already up"
    tag = "jpduchesne89/snappy-linux:content-abc"
    root = Pathname("/proj")
    name = Dev::BuildContainer.service_container_name(tag, root)
    bc = build_container

    When "ensuring the service"
    bc.ensure_service!(tag, project_root: root)

    Then "neither start nor create is invoked"
    1 * bc.reap_stale_services!(tag, root) >> nil
    1 * bc.container_exists?(name) >> true
    1 * bc.container_running?(name) >> true
    0 * bc.start_container(name)
  end

  test "reap_stale_services! removes other-tag containers but keeps the current tag" do
    Given "a current tag and a stale sibling container in the same checkout"
    tag = "jpduchesne89/snappy-linux:content-new"
    root = Pathname("/proj")
    keep = service(Dev::BuildContainer.service_container_name(tag, root), running: true)
    stale = service(Dev::BuildContainer.service_container_name("jpduchesne89/snappy-linux:content-old", root),
      running: false)
    bc = build_container

    When "reaping"
    bc.reap_stale_services!(tag, root)

    Then "only the non-current container is removed"
    1 * bc.service_containers(root) >> [stale, keep]
    1 * bc.remove_container(stale.name) >> true
    0 * bc.remove_container(keep.name)
  end

  test "reset_service! removes every container for the checkout" do
    Given "two containers for the checkout (current and stale)"
    root = Pathname("/proj")
    current = service("dev-snappy-linux-abc-content-abc", running: true)
    stale = service("dev-snappy-linux-abc-content-old", running: false)
    bc = build_container

    When "resetting"
    result = bc.reset_service!(root)

    Then "all of the checkout's containers are removed and their names returned"
    result == [stale.name, current.name]
    1 * bc.service_containers(root) >> [stale, current]
    1 * bc.remove_container(stale.name) >> true
    1 * bc.remove_container(current.name) >> true
  end

  test "stop_service! stops the checkout's running containers with no grace period, keeping them" do
    Given "a running and a stopped container for the checkout"
    root = Pathname("/proj")
    running = service("dev-snappy-linux-abc-content-abc", running: true)
    stopped = service("dev-snappy-linux-abc-content-old", running: false)
    engine = FakeContainerEngine.new
    bc = build_container(engine: engine)
    bc.stubs(:service_containers).with(root).returns([stopped, running])

    When "stopping"
    result = bc.stop_service!(root)

    Then "only the running one is stopped (-t 0: PID 1 is sleep, which ignores SIGTERM); nothing is removed"
    result == [running.name]
    engine.runs == [["stop", "-t", "0", running.name]]
  end

  test "stop_service! raises when a container will not stop" do
    Given "a running container whose stop fails"
    root = Pathname("/proj")
    bc = build_container(engine: FakeContainerEngine.new { |_args| false })
    bc.stubs(:service_containers).returns([service("dev-x", running: true)])

    When "stopping"
    bc.stop_service!(root)

    Then
    error = raises Dev::BuildContainer::StopFailedError
    error.message == "could not stop container dev-x."
  end

  test "stop_service! on a checkout with nothing running returns no names" do
    Given "no containers for the checkout"
    engine = FakeContainerEngine.new(capture_result: "")
    bc = build_container(engine: engine)

    Expect "nothing stopped, nothing run"
    bc.stop_service!(Pathname("/proj")) == []
    engine.runs == []
  end

  test "service_status gathers image presence and the checkout's containers" do
    Given "a local image, a registry copy, and a current + stale container"
    tag = "jpduchesne89/snappy-linux:content-abc"
    root = Pathname("/proj")
    current = service(Dev::BuildContainer.service_container_name(tag, root), running: true)
    stale = service(Dev::BuildContainer.service_container_name("jpduchesne89/snappy-linux:content-old", root), running: false)
    bc = build_container
    bc.stubs(:local_image?).with(tag).returns(true)
    bc.stubs(:registry_has?).with(tag).returns(false)
    bc.stubs(:service_containers).with(root).returns([stale, current])

    When "reporting"
    status = bc.service_status(tag, root)

    Then "one record, the current container named so the renderer can tell it from stale ones"
    status.image_tag == tag
    status.local_image == true
    status.in_registry == false
    status.current_container_name == current.name
    status.containers == [stale, current]
  end

  test "reap_stale_services! and service_status keep to the image's own containers: another image's are not stale siblings (dev#307)" do
    Given "a checkout with two persisted images, each with a container, and a stale one of the first"
    root = Pathname("/proj")
    linux = "ghcr.io/d3mlabs/snappy-linux:aaaa"
    server = "ghcr.io/d3mlabs/snappy-server:bbbb"
    linux_current = service(Dev::BuildContainer.service_container_name(linux, root), running: true)
    linux_stale = service(Dev::BuildContainer.service_container_name("ghcr.io/d3mlabs/snappy-linux:0000", root), running: false)
    server_current = service(Dev::BuildContainer.service_container_name(server, root), running: true)
    bc = build_container
    bc.stubs(:service_containers).with(root).returns([linux_stale, linux_current, server_current])
    bc.stubs(:local_image?).returns(true)
    bc.stubs(:registry_has?).returns(true)

    When "reaping for the first image, and reporting on it"
    bc.reap_stale_services!(linux, root)
    status = bc.service_status(linux, root)

    Then "only the first image's stale container goes; the report lists the first image's containers alone"
    1 * bc.remove_container(linux_stale.name) >> true
    0 * bc.remove_container(server_current.name)
    status.containers == [linux_stale, linux_current]
  end

  test "service_status probes the registry inside a login session when told the registry: read scope, the probe, logout (dev#313)" do
    Given "a pinned image on a private registry, and a recording login"
    tag = "ghcr.io/d3mlabs/snappy-linux:aaaa"
    root = Pathname("/proj")
    login = FakeRegistryLogin.new
    bc = Dev::BuildContainer.new(engine: FakeContainerEngine.new, registry_login: login)
    bc.stubs(:local_image?).with(tag).returns(false)
    bc.stubs(:registry_has?).with(tag).returns(true)
    bc.stubs(:service_containers).with(root).returns([])

    When
    status = bc.service_status(tag, root, registry: "ghcr.io")

    Then "the registry's answer, asked from inside the session"
    status.in_registry == true
    login.sessions == [["ghcr.io", false]]
  end

  test "service_status without a credential to ask with leaves the registry half unknown rather than claiming absence (dev#313)" do
    Given "a host with no gh auth: the login refuses with #{error}"
    tag = "ghcr.io/d3mlabs/snappy-linux:aaaa"
    root = Pathname("/proj")
    login = FakeRegistryLogin.new
    login.stubs(:with).raises(error, "no")
    bc = Dev::BuildContainer.new(engine: FakeContainerEngine.new, registry_login: login)
    bc.stubs(:local_image?).with(tag).returns(true)
    bc.stubs(:service_containers).with(root).returns([])

    When
    status = bc.service_status(tag, root, registry: "ghcr.io")

    Then "the local half is still answered; the registry half is nil"
    status.local_image == true
    status.in_registry.nil?
    0 * bc.registry_has?(tag)

    Where
    error                                   | _
    Dev::GhAuth::NotAuthenticatedError      | nil
    Dev::GhAuth::MissingScopeError          | nil
    Dev::GhAuth::GhMissingError             | nil
    Dev::RegistryLogin::LoginFailedError    | nil
  end

  test "create_service_container runs detached, mounts project + volumes, idles, and carries the label contract" do
    Given "a recording engine and the checkout's labels"
    engine = FakeContainerEngine.new
    root = Pathname("/project")
    labels = Dev::BuildContainer.service_labels("img:tag", root)

    When "creating the service container"
    build_container(engine: engine).create_service_container(
      "dev-x", "img:tag",
      project_root: root, volumes: ["/engines/ue:/ue"],
    )

    Then "it is a detached, named run that bind-mounts the project + engine and sleeps"
    engine.runs.last[0, 4] == ["run", "-d", "--name", "dev-x"]
    engine.runs.last.include?("/project:/project")
    engine.runs.last.include?("/engines/ue:/ue")
    engine.runs.last.include?("img:tag")
    engine.runs.last.last(2) == ["sleep", "infinity"]
    labels.all? { |key, value| engine.runs.last.each_cons(2).include?(["--label", "#{key}=#{value}"]) }
  end

  test "create_service_container marks the container as inside, so every later docker exec inherits it" do
    Given "a recording engine"
    engine = FakeContainerEngine.new

    When "creating the service container"
    build_container(engine: engine).create_service_container(
      "dev-x", "img:tag", project_root: Pathname("/project"), volumes: [],
    )

    Then "the detached run names DEV_INSIDE_CONTAINER before the image; its value rides the run's env"
    run = engine.runs.last
    run.each_cons(2).include?(["-e", "DEV_INSIDE_CONTAINER"])
    run.index("DEV_INSIDE_CONTAINER") < run.index("img:tag")
    engine.run_envs.last["DEV_INSIDE_CONTAINER"] == "1"
  end

  test "create_service_container mounts the same two volumes as a one-shot run, so a recreated container finds its data root warm" do
    Given "a recording engine and a host data root that must not leak in"
    engine = FakeContainerEngine.new
    root = Dir.mktmpdir("dev-data-root")
    original = ENV["DEV_DATA_ROOT"]
    ENV["DEV_DATA_ROOT"] = root

    When "creating the service container"
    build_container(engine: engine).create_service_container(
      "dev-x", "img:tag", project_root: Pathname("/project"), volumes: [],
    )

    Then "the detached run mounts both volumes, sets DEV_DATA_ROOT, and names no host path"
    run = engine.runs.last
    run.each_cons(2).include?(["-v", "dev-data-root:/var/lib/dev"])
    run.each_cons(2).include?(["-v", "dev-linuxbrew:/home/linuxbrew/.linuxbrew"])
    run.each_cons(2).include?(["-e", "DEV_DATA_ROOT"])
    engine.run_envs.last["DEV_DATA_ROOT"] == "/var/lib/dev"
    run.none? { |part| part.include?(root) }

    Cleanup
    ENV["DEV_DATA_ROOT"] = original
    FileUtils.rm_rf(root)
  end

  test "docker_run_command carries the label contract so dev engine down recognizes an in-flight --rm run" do
    Given "the checkout's labels"
    root = Pathname("/project")
    labels = Dev::BuildContainer.service_labels("img:tag", root)

    When "building a one-shot run"
    cmd = build_container.docker_run_command("img:tag", project_root: root, shell_cmd: "make").argv

    Then "every label precedes the image"
    labels.all? { |key, value| cmd.each_cons(2).include?(["--label", "#{key}=#{value}"]) }
    cmd.index("--label") < cmd.index("img:tag")
  end

  test "service_labels is the contract dev reads back: managed, the checkout's real path and name, workspace id, image" do
    Given "a checkout reached through a symlink"
    dir = Dir.mktmpdir("build-container-labels-")
    real = File.realpath(dir)
    link = File.join(Dir.mktmpdir("build-container-link-"), "snappy")
    File.symlink(real, link)
    root = Pathname(link)

    When "computing the labels"
    labels = Dev::BuildContainer.service_labels("reg/snappy-linux:content-abc", root)

    Then "they resolve the symlink, so one checkout has one identity however it is reached"
    labels == {
      Dev::ContainerEngine::MANAGED_LABEL => "true",
      Dev::ContainerEngine::PROJECT_ROOT_LABEL => real,
      Dev::BuildContainer::PROJECT_LABEL => File.basename(real),
      Dev::BuildContainer::WORKSPACE_LABEL => Dev::BuildContainer.workspace_id(root),
      Dev::BuildContainer::IMAGE_LABEL => "reg/snappy-linux:content-abc",
    }

    Cleanup
    FileUtils.rm_rf(dir)
    FileUtils.rm_rf(File.dirname(link))
  end

  test "create_service_container raises when docker run fails" do
    Given "an engine whose runs fail"
    engine = FakeContainerEngine.new { |_args| false }

    When "docker run fails"
    build_container(engine: engine).create_service_container(
      "dev-x", "img:tag", project_root: Pathname("/project"),
    )

    Then
    raises RuntimeError
  end

  test "with_one_shot_container creates a --rm sibling of the service container, yields its name, and removes it after" do
    Given "a recording engine"
    engine = FakeContainerEngine.new
    root = Pathname("/project")
    service_name = Dev::BuildContainer.service_container_name("img:tag", root)
    seen = {}

    When "running a block in a one-shot container"
    build_container(engine: engine).with_one_shot_container("img:tag", project_root: root, volumes: ["/e:/ue"]) do |name|
      seen[:name] = name
      seen[:runs_so_far] = engine.runs.size
    end

    Then "the name is the service's plus a cold suffix, the run is detached and --rm with the same mounts and labels, and rm -f follows the block"
    seen[:name].start_with?("#{service_name}-cold-")
    seen[:name] != service_name
    engine.runs[0, 2] == [["volume", "create", "dev-data-root"], ["volume", "create", "dev-linuxbrew"]]
    create = engine.runs.fetch(2)
    create[0, 2] == ["run", "-d"]
    create.include?("--rm")
    create.each_cons(2).include?(["--name", seen[:name]])
    create.include?("/project:/project")
    create.include?("/e:/ue")
    create.each_cons(2).include?(["-e", "DEV_INSIDE_CONTAINER"])
    engine.run_envs.fetch(2)["DEV_INSIDE_CONTAINER"] == "1"
    create.last(2) == ["sleep", "infinity"]
    Dev::BuildContainer.service_labels("img:tag", root).all? { |k, v| create.each_cons(2).include?(["--label", "#{k}=#{v}"]) }
    seen[:runs_so_far] == 3
    engine.runs.last == ["rm", "-f", seen[:name]]
  end

  test "with_one_shot_container removes the container even when the block raises" do
    Given "a recording engine"
    engine = FakeContainerEngine.new
    seen = {}

    When "the block fails"
    begin
      build_container(engine: engine).with_one_shot_container("img:tag", project_root: Pathname("/project")) do |name|
        seen[:name] = name
        raise "install exploded"
      end
    rescue RuntimeError
      nil
    end

    Then "rm -f still ran"
    engine.runs.last == ["rm", "-f", seen[:name]]
  end

  test "with_one_shot_container raises when the container cannot be created, and runs no block" do
    Given "an engine whose runs fail"
    engine = FakeContainerEngine.new { |_args| false }
    ran = false

    When "creating"
    build_container(engine: engine).with_one_shot_container("img:tag", project_root: Pathname("/project")) { |_name| ran = true }

    Then
    raises RuntimeError
    ran == false
  end

  test "prewarm_container_name embeds the pid and never repeats" do
    Given "the instance under test"
    bc = build_container

    When "naming two prewarm containers"
    name_a = bc.prewarm_container_name
    name_b = bc.prewarm_container_name

    Then "both carry the dev-prewarm-<pid>- prefix and differ in their random suffix"
    name_a.start_with?("dev-prewarm-#{Process.pid}-")
    name_b.start_with?("dev-prewarm-#{Process.pid}-")
    name_a != name_b
  end

  test "the docker CLI wrappers compose their args through the engine and pass its success through" do
    Given "an engine whose every invocation succeeds"
    engine = FakeContainerEngine.new
    bc = build_container(engine: engine)

    When "invoking every one-command wrapper"
    bc.remove_image("img:tag")
    exists = bc.container_exists?("dev-x")
    bc.start_container("dev-x")
    bc.remove_container("dev-x")
    local = bc.local_image?("img:tag")
    pulled = bc.pull("img:tag")
    pushed = bc.push!("img:tag")
    advertised = bc.registry_has?("img:tag")

    Then "each predicate reports the engine's success, and the recorded argv names each docker subcommand"
    exists && local && pulled && pushed && advertised
    engine.runs == [
      ["image", "rm", "-f", "img:tag"],
      ["container", "inspect", "dev-x"],
      ["start", "dev-x"],
      ["rm", "-f", "dev-x"],
      ["image", "inspect", "img:tag"],
      ["pull", "img:tag"],
      ["push", "img:tag"],
      ["manifest", "inspect", "img:tag"],
    ]
  end

  test "service_containers lists the checkout's containers by workspace label, running or not" do
    Given "docker ps reporting a running and an exited container, with surrounding noise"
    root = Pathname("/proj")
    engine = FakeContainerEngine.new(
      capture_result: "dev-snappy-abc-content-1\trunning\ndev-snappy-abc-content-2\texited\n\n",
    )
    bc = build_container(engine: engine)

    Expect "records in docker's order, from the label filter (a name regex would also match other checkouts' prefixes)"
    bc.service_containers(root).map { |c| [c.name, c.running] } == [
      ["dev-snappy-abc-content-1", true],
      ["dev-snappy-abc-content-2", false],
    ]
    engine.captures.last == [
      "ps", "-a",
      "--filter", "label=#{Dev::BuildContainer::WORKSPACE_LABEL}=#{Dev::BuildContainer.workspace_id(root)}",
      "--format", "{{.Names}}\t{{.State}}",
    ]
  end

  test "container_running? reflects the inspected running state" do
    Given "docker inspect reporting the state"
    engine = FakeContainerEngine.new(capture_result: "true\n")

    Expect "the container counts as running"
    build_container(engine: engine).container_running?("dev-x") == true
  end

  test "run_watched delegates the build to a watcher named for the container, riding the same engine" do
    Given "a watcher primed for the prewarm command"
    argv = ["docker", "run", "--name", "dev-prewarm-1", "img:tag"]
    engine = FakeContainerEngine.new
    watcher = mock
    watcher.expects(:run).with(argv).returns(true)
    Dev::BuildWatcher.expects(:new).with(container_name: "dev-prewarm-1", engine: engine).returns(watcher)

    Expect "the watcher's verdict is returned"
    build_container(engine: engine).run_watched(argv, container: "dev-prewarm-1") == true
  end
end

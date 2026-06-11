# typed: false
# frozen_string_literal: true

require "test_helper"
require "build_container"
require "dev/build_container_config"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class BuildContainerTest < Minitest::Test
  test "content_tag produces deterministic hash from Dockerfile and lockfile" do
    Given "a project with Dockerfile and build-deps.lock"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    File.write(File.join(dir, "build-deps.lock"), "cmake: {version: 3.31}")

    When "computing the tag"
    tag = BuildContainer.content_tag(project_root: Pathname(dir))

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
    tag_a = BuildContainer.content_tag(project_root: Pathname(dir))

    When "the Dockerfile changes"
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:25.04")
    tag_b = BuildContainer.content_tag(project_root: Pathname(dir))

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
    tag_a = BuildContainer.content_tag(project_root: Pathname(dir))
    tag_b = BuildContainer.content_tag(project_root: Pathname(dir))

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
    tag = BuildContainer.content_tag(project_root: Pathname(dir))

    Then
    tag.start_with?("content-")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "image_with_tag combines config and content tag" do
    Given "a config and project"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")

    When "computing the full image reference"
    result = BuildContainer.image_with_tag(config, project_root: Pathname(dir))

    Then
    result.start_with?("jpduchesne89/snappy-linux:content-")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "docker_run_command produces correct command array" do
    When "building a docker run command"
    cmd = BuildContainer.docker_run_command(
      "jpduchesne89/snappy:content-abc123",
      project_root: Pathname("/project"),
      shell_cmd: "./bin/build.sh",
    )

    Then
    cmd[0] == "docker"
    cmd[1] == "run"
    cmd.include?("--rm")
    cmd.include?("-v")
    cmd.include?("/project:/project")
    cmd.last(3) == ["sh", "-c", "./bin/build.sh"]
  end

  test "docker_run_command renders extra volume mounts" do
    When "building a docker run command with volumes"
    cmd = BuildContainer.docker_run_command(
      "jpduchesne89/snappy:content-abc123",
      project_root: Pathname("/project"),
      shell_cmd: "./bin/build.sh",
      volumes: ["/opt/engines/ue:/ue", "/var/cache/wwise:/wwise"],
    )

    Then
    cmd.include?("/opt/engines/ue:/ue")
    cmd.include?("/var/cache/wwise:/wwise")
    cmd[cmd.index("/opt/engines/ue:/ue") - 1] == "-v"
    cmd[cmd.index("/var/cache/wwise:/wwise") - 1] == "-v"
    cmd.index("-w") > cmd.index("/var/cache/wwise:/wwise")
  end

  test "docker_run_command expands ~ in volume host paths" do
    When "building a docker run command with a ~ volume"
    cmd = BuildContainer.docker_run_command(
      "jpduchesne89/snappy:content-abc123",
      project_root: Pathname("/project"),
      shell_cmd: "./bin/build.sh",
      volumes: ["~/.dev/engines/unreal-engine-css:/ue"],
    )

    Then
    cmd.include?("#{File.expand_path("~/.dev/engines/unreal-engine-css")}:/ue")
    !cmd.any? { |part| part.start_with?("~") }
  end

  test "ensure_image! returns existing image on pull hit" do
    Given "a project and config where pull succeeds"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")

    When "ensuring the image"
    BuildContainer.stubs(:local_image?).returns(false)
    BuildContainer.stubs(:pull).returns(true)
    result = BuildContainer.ensure_image!(config, project_root: Pathname(dir))

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

    When "ensuring the image with a build args provider"
    BuildContainer.stubs(:local_image?).returns(false)
    BuildContainer.stubs(:pull).returns(false)
    BuildContainer.stubs(:build!).with { |_tag, build_args:, **_| received_args = build_args; true }
    BuildContainer.stubs(:push!).returns(true)
    BuildContainer.ensure_image!(
      config,
      project_root: Pathname(dir),
      build_args_provider: -> { provider_calls += 1; { "WWISE_EMAIL" => "me@example.com" } },
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

    When "ensuring the image"
    BuildContainer.stubs(:local_image?).returns(false)
    BuildContainer.stubs(:pull).returns(true)
    BuildContainer.ensure_image!(
      config,
      project_root: Pathname(dir),
      build_args_provider: -> { provider_calls += 1; {} },
    )

    Then
    provider_calls == 0

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "build! passes build args as --build-arg flags" do
    Given "a project root and captured docker invocation"
    dir = Dir.mktmpdir("build-container-test-")
    captured = nil

    When "building with build args"
    BuildContainer.stubs(:system).with { |*argv| captured = argv; true }.returns(true)
    BuildContainer.send(
      :build!,
      "img:tag",
      project_root: Pathname(dir),
      build_args: { "WWISE_EMAIL" => "me@example.com", "WWISE_PASSWORD" => "hunter2" },
    )

    Then
    captured.include?("--build-arg")
    captured.include?("WWISE_EMAIL=me@example.com")
    captured.include?("WWISE_PASSWORD=hunter2")
    captured.last == dir

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure_image! prefers a local image over pulling or building" do
    Given "a project whose image already exists locally"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")
    pulled = []

    When "ensuring the image"
    BuildContainer.stubs(:local_image?).returns(true)
    BuildContainer.stubs(:pull).with { |tag| pulled << tag; true }
    result = BuildContainer.ensure_image!(config, project_root: Pathname(dir))

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

    When "ensuring the image"
    BuildContainer.stubs(:local_image?).returns(false)
    BuildContainer.stubs(:pull).returns(false)
    BuildContainer.stubs(:build!).with { |tag, **_| built << tag; true }
    BuildContainer.stubs(:push!).with { |tag| pushed << tag; true }
    result = BuildContainer.ensure_image!(config, project_root: Pathname(dir))

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

    When "ensuring the image with push: false"
    BuildContainer.stubs(:local_image?).returns(false)
    BuildContainer.stubs(:pull).returns(false)
    BuildContainer.stubs(:build!).returns(true)
    BuildContainer.stubs(:push!).with { |tag| pushed << tag; true }
    BuildContainer.ensure_image!(config, project_root: Pathname(dir), push: false)

    Then
    pushed.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "build! raises when docker build fails" do
    Given "a project root"
    dir = Dir.mktmpdir("build-container-test-")

    When "docker build fails"
    BuildContainer.stubs(:system).returns(false)
    BuildContainer.send(:build!, "bad:tag", project_root: Pathname(dir))

    Then
    raises RuntimeError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "content_tag includes .dockerignore in hash" do
    Given "a project with Dockerfile and .dockerignore"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    tag_without = BuildContainer.content_tag(project_root: Pathname(dir))

    When "adding a .dockerignore"
    File.write(File.join(dir, ".dockerignore"), "node_modules")
    tag_with = BuildContainer.content_tag(project_root: Pathname(dir))

    Then
    tag_without != tag_with

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

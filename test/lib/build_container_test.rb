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

  test "docker_run_command renders env vars as -e flags" do
    When "building a docker run command with env"
    cmd = BuildContainer.docker_run_command(
      "jpduchesne89/snappy:content-abc123",
      project_root: Pathname("/project"),
      shell_cmd: "./bin/build.sh",
      env: { "WWISE_TOKEN" => "tok-123" },
    )

    Then
    cmd.include?("WWISE_TOKEN=tok-123")
    cmd[cmd.index("WWISE_TOKEN=tok-123") - 1] == "-e"
    cmd.index("-w") > cmd.index("WWISE_TOKEN=tok-123")
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

  test "ensure_image! publishes a locally-resolved image when publish is requested" do
    Given "an image present locally but absent from the registry"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")
    tag = BuildContainer.image_with_tag(config, project_root: Pathname(dir))

    When "ensuring the image with publish: true"
    result = BuildContainer.ensure_image!(config, project_root: Pathname(dir), publish: true)

    Then "the local image is honored, then published to the registry (no pull, no build)"
    result == tag
    1 * BuildContainer.local_image?(tag) >> true
    0 * BuildContainer.pull(tag)
    1 * BuildContainer.registry_has?(tag) >> false
    1 * BuildContainer.push!(tag) >> true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure_image! does not re-push a locally-resolved image already in the registry" do
    Given "an image present locally and already advertised by the registry"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")
    tag = BuildContainer.image_with_tag(config, project_root: Pathname(dir))

    When "ensuring the image with publish: true"
    result = BuildContainer.ensure_image!(config, project_root: Pathname(dir), publish: true)

    Then "the registry check short-circuits the push"
    result == tag
    1 * BuildContainer.local_image?(tag) >> true
    1 * BuildContainer.registry_has?(tag) >> true
    0 * BuildContainer.push!(tag)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure_image! does not publish a local hit by default" do
    Given "an image present locally and publish left at its default"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")
    tag = BuildContainer.image_with_tag(config, project_root: Pathname(dir))

    When "ensuring the image"
    result = BuildContainer.ensure_image!(config, project_root: Pathname(dir))

    Then "no registry interaction happens — a plain local run never publishes"
    result == tag
    1 * BuildContainer.local_image?(tag) >> true
    0 * BuildContainer.registry_has?(tag)
    0 * BuildContainer.push!(tag)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure_image! publishes a freshly built image when publish is requested" do
    Given "a project that misses both caches and is provisioned with publish"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")
    tag = BuildContainer.image_with_tag(config, project_root: Pathname(dir))

    When "ensuring the image with push: false (the only real caller) and publish: true"
    result = BuildContainer.ensure_image!(config, project_root: Pathname(dir), push: false, publish: true)

    Then "it builds, then publishes via the registry-guarded path"
    result == tag
    1 * BuildContainer.local_image?(tag) >> false
    1 * BuildContainer.pull(tag) >> false
    1 * BuildContainer.build!(tag, project_root: Pathname(dir), build_args: {}, build_contexts: {}, secrets: {}) >> true
    1 * BuildContainer.registry_has?(tag) >> false
    1 * BuildContainer.push!(tag) >> true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "publish! is a no-op when the registry already advertises the tag" do
    When "publishing a tag the registry already has"
    result = BuildContainer.publish!("img:tag")

    Then "the manifest check short-circuits and nothing is pushed"
    result == true
    1 * BuildContainer.registry_has?("img:tag") >> true
    0 * BuildContainer.push!("img:tag")
  end

  test "publish! pushes when the registry lacks the tag" do
    When "publishing a tag the registry lacks"
    result = BuildContainer.publish!("img:tag")

    Then "it pushes the local image"
    result == true
    1 * BuildContainer.registry_has?("img:tag") >> false
    1 * BuildContainer.push!("img:tag") >> true
  end

  test "publish! warns but does not raise when the push fails" do
    When "the registry lacks the tag and the push fails"
    result = BuildContainer.publish!("img:tag")

    Then "the failure is surfaced as a falsey return, not an exception"
    result == false
    1 * BuildContainer.registry_has?("img:tag") >> false
    1 * BuildContainer.push!("img:tag") >> false
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

  test "content_tag includes deps.lock in hash" do
    Given "a project with a Dockerfile"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    tag_without = BuildContainer.content_tag(project_root: Pathname(dir))

    When "adding a deps.lock"
    File.write(File.join(dir, "deps.lock"), "SML: {version: 3.12.0}")
    tag_with = BuildContainer.content_tag(project_root: Pathname(dir))

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
    tag_a = BuildContainer.content_tag(project_root: Pathname(dir), extra_globs: globs)

    When "the Build.cs changes"
    File.write(build_cs, "// deps: Core, SML")
    tag_b = BuildContainer.content_tag(project_root: Pathname(dir), extra_globs: globs)

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
    tag_a = BuildContainer.content_tag(project_root: Pathname(dir), extra_globs: globs)
    File.write(File.join(dir, "bin/image/lib/env.sh"), "echo env changed")
    tag_b = BuildContainer.content_tag(project_root: Pathname(dir), extra_globs: globs)

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
    tag_a = BuildContainer.content_tag(project_root: Pathname(dir), extra_globs: globs)

    When "a non-globbed source file changes"
    File.write(File.join(dir, "Mods/Snappy/Source/Snappy/Snappy.cpp"), "int main() {}")
    tag_b = BuildContainer.content_tag(project_root: Pathname(dir), extra_globs: globs)

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
    tag_a = BuildContainer.content_tag(project_root: Pathname(dir), structure_globs: globs)

    When "the Build.cs contents change but the module set does not"
    File.write(build_cs, "// deps: Core, UMG, Slate, AssetRegistry")
    tag_b = BuildContainer.content_tag(project_root: Pathname(dir), structure_globs: globs)

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
    tag_a = BuildContainer.content_tag(project_root: Pathname(dir), structure_globs: globs)

    When "a second module is added (a new Build.cs path)"
    FileUtils.mkdir_p(File.join(dir, "Mods/Snappy/Source/SnappyTests"))
    File.write(File.join(dir, "Mods/Snappy/Source/SnappyTests/SnappyTests.Build.cs"), "// deps")
    tag_b = BuildContainer.content_tag(project_root: Pathname(dir), structure_globs: globs)

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
    tag_a = BuildContainer.content_tag(project_root: Pathname(dir), structure_globs: globs)

    When "a module is removed (its Build.cs path disappears)"
    File.delete(tests_cs)
    tag_b = BuildContainer.content_tag(project_root: Pathname(dir), structure_globs: globs)

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
    ref_a = BuildContainer.image_with_tag(config, project_root: Pathname(dir))

    When "a module is added"
    FileUtils.mkdir_p(File.join(dir, "Mods/Snappy/Source/SnappyTests"))
    File.write(File.join(dir, "Mods/Snappy/Source/SnappyTests/SnappyTests.Build.cs"), "// deps")
    ref_b = BuildContainer.image_with_tag(config, project_root: Pathname(dir))

    Then "the full image reference changes via the structural path set"
    ref_a != ref_b
    ref_a.start_with?("jpduchesne89/snappy-linux:content-")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "build_contexts_from_lockfile returns build-group install_dirs" do
    Given "a build-deps.lock with an engine install_dir and a context-less dep"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "build-deps.lock"), <<~LOCK)
      UnrealEngine:
        integration: gh
        group: build
        install_dir: "~/.dev/engines/unreal-engine-css"
      wwise-cli:
        integration: brew
        group: build
    LOCK

    When "computing build contexts"
    contexts = BuildContainer.build_contexts_from_lockfile(Pathname(dir))

    Then "the context name is lowercased (Docker rejects uppercase)"
    contexts == { "unrealengine" => File.expand_path("~/.dev/engines/unreal-engine-css") }

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "build_contexts_from_lockfile points at the version-keyed subdir when a version is locked" do
    Given "a build-deps.lock whose engine dep declares a version"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "build-deps.lock"), <<~LOCK)
      UnrealEngine:
        integration: gh
        group: build
        version: "5.6.1-css-83"
        install_dir: "~/.dev/engines/unreal-engine-css"
    LOCK

    When "computing build contexts"
    contexts = BuildContainer.build_contexts_from_lockfile(Pathname(dir))

    Then "the host path includes the locked version"
    contexts == { "unrealengine" => File.join(File.expand_path("~/.dev/engines/unreal-engine-css"), "5.6.1-css-83") }

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "resolve_versioned_volumes rewrites a locked install_dir volume to its versioned subdir" do
    Given "lockfiles pinning an engine (build) and a server (integration) install_dir"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "build-deps.lock"), <<~LOCK)
      UnrealEngine:
        integration: gh
        group: build
        version: "5.6.1-css-83"
        install_dir: "/opt/engines/ue"
    LOCK
    File.write(File.join(dir, "deps.lock"), <<~LOCK)
      SatisfactoryServer:
        integration: steam
        group: integration
        version: "15321746"
        install_dir: "/opt/satisfactory-server"
    LOCK

    When "resolving a mix of locked and unlocked volumes"
    resolved = BuildContainer.resolve_versioned_volumes(
      ["/opt/engines/ue:/ue", "/opt/satisfactory-server:/server", "~/.dev/cache:/cache:ro"],
      project_root: Pathname(dir),
    )

    Then "locked volumes gain their version subdir; the cache volume (and its :ro) is untouched"
    resolved == [
      "/opt/engines/ue/5.6.1-css-83:/ue",
      "/opt/satisfactory-server/15321746:/server",
      "~/.dev/cache:/cache:ro",
    ]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "resolve_versioned_volumes is identity when no lockfiles are present" do
    Given "a project with no lockfiles"
    dir = Dir.mktmpdir("build-container-test-")

    When "resolving volumes"
    resolved = BuildContainer.resolve_versioned_volumes(["/opt/engines/ue:/ue"], project_root: Pathname(dir))

    Then
    resolved == ["/opt/engines/ue:/ue"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_dir_versions collects env-nested build deps that declare a version" do
    Given "a build-deps.lock with an env-scoped install_dir"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "build-deps.lock"), <<~LOCK)
      env:
        ci:
          UnrealEngine:
            integration: gh
            group: build
            version: "5.6.1-css-83"
            install_dir: "/opt/engines/ue"
    LOCK

    When "collecting install_dir versions"
    versions = BuildContainer.install_dir_versions(Pathname(dir))

    Then
    versions == { "/opt/engines/ue" => "5.6.1-css-83" }

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "build_contexts_from_lockfile is empty without a lockfile" do
    Given "a project with no build-deps.lock"
    dir = Dir.mktmpdir("build-container-test-")

    When "computing build contexts"
    contexts = BuildContainer.build_contexts_from_lockfile(Pathname(dir))

    Then
    contexts == {}

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "build! passes build contexts and secrets with BuildKit enabled" do
    Given "a project root and captured docker invocation"
    dir = Dir.mktmpdir("build-container-test-")
    captured = nil

    When "building with contexts and secrets"
    BuildContainer.stubs(:system).with { |*argv| captured = argv; true }.returns(true)
    BuildContainer.send(
      :build!,
      "img:tag",
      project_root: Pathname(dir),
      build_contexts: { "UnrealEngine" => "/engines/ue" },
      secrets: { "WWISE_TOKEN" => "tok-123" },
    )

    Then "BuildKit env, build-context flag, and secret flag are present"
    captured[0].is_a?(Hash)
    captured[0]["DOCKER_BUILDKIT"] == "1"
    captured[0]["WWISE_TOKEN"] == "tok-123"
    captured.include?("--build-context")
    captured.include?("UnrealEngine=/engines/ue")
    captured.include?("--secret")
    captured.include?("id=WWISE_TOKEN,env=WWISE_TOKEN")
    captured.last == dir
  end

  test "build! keeps the secret value off argv" do
    Given "a project root and captured docker invocation"
    dir = Dir.mktmpdir("build-container-test-")
    captured = nil

    When "building with a secret"
    BuildContainer.stubs(:system).with { |*argv| captured = argv; true }.returns(true)
    BuildContainer.send(
      :build!,
      "img:tag",
      project_root: Pathname(dir),
      secrets: { "WWISE_TOKEN" => "super-secret" },
    )

    Then "the value travels via env, never as an argument"
    captured.drop(1).none? { |part| part.is_a?(String) && part.include?("super-secret") }

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure_image! resolves secrets lazily and passes contexts on cache miss" do
    Given "a project whose image must be built, with an engine build dep"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    File.write(File.join(dir, "build-deps.lock"), <<~LOCK)
      UnrealEngine:
        integration: gh
        group: build
        install_dir: "/engines/ue"
    LOCK
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")
    secret_calls = 0
    received_secrets = nil
    received_contexts = nil

    When "ensuring the image with a secrets provider"
    BuildContainer.stubs(:local_image?).returns(false)
    BuildContainer.stubs(:pull).returns(false)
    BuildContainer.stubs(:build!).with do |_tag, secrets:, build_contexts:, **_|
      received_secrets = secrets
      received_contexts = build_contexts
      true
    end
    BuildContainer.stubs(:push!).returns(true)
    BuildContainer.ensure_image!(
      config,
      project_root: Pathname(dir),
      build_args_provider: -> { {} },
      secrets_provider: -> { secret_calls += 1; { "WWISE_TOKEN" => "tok" } },
    )

    Then
    secret_calls == 1
    received_secrets == { "WWISE_TOKEN" => "tok" }
    received_contexts == { "unrealengine" => "/engines/ue" }

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure_image! does not invoke the secrets provider on cache hit" do
    Given "a project whose image pulls successfully"
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")
    secret_calls = 0

    When "ensuring the image"
    BuildContainer.stubs(:local_image?).returns(false)
    BuildContainer.stubs(:pull).returns(true)
    BuildContainer.ensure_image!(
      config,
      project_root: Pathname(dir),
      secrets_provider: -> { secret_calls += 1; {} },
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
    tag = BuildContainer.image_with_tag(config, project_root: Pathname(dir))

    When "ensuring the image"
    result = BuildContainer.ensure_image!(config, project_root: Pathname(dir))

    Then "the base is built engine-free, the prewarm runs against it, and the base tag is dropped"
    result == tag
    1 * BuildContainer.local_image?(tag) >> false
    1 * BuildContainer.pull(tag) >> false
    1 * BuildContainer.build!("#{tag}-base", project_root: Pathname(dir), build_args: {},
      build_contexts: {}, secrets: {}) >> true
    1 * BuildContainer.prewarm_commit!("#{tag}-base", tag, volumes: ["/engines/ue:/ue"],
      prewarm: "bash /work/bin/prewarm.sh", secrets: {}) >> true
    1 * BuildContainer.remove_image("#{tag}-base") >> true
    1 * BuildContainer.push!(tag) >> true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "prewarm_commit! runs the prewarm with dep volumes and secret files, commits, and cleans up" do
    Given "resolved dep volumes and a secret"

    When "running the prewarm commit"
    BuildContainer.send(
      :prewarm_commit!, "img:tag-base", "img:tag",
      volumes: ["/engines/ue:/ue"], prewarm: "bash /work/bin/prewarm.sh", secrets: { "WWISE_TOKEN" => "tok" }
    )

    Then "the run mounts the engine + secret file (never -e: commit would bake env), runs under the watcher, commits, and removes it"
    1 * BuildContainer.prewarm_container_name >> "dev-prewarm-test"
    1 * BuildContainer.write_secret_files({ "WWISE_TOKEN" => "tok" }) >> { "WWISE_TOKEN" => "/tmp/dev-secret-xyz" }
    1 * BuildContainer.run_watched(["docker", "run", "--name", "dev-prewarm-test",
      "-v", "/engines/ue:/ue",
      "-v", "/tmp/dev-secret-xyz:/run/secrets/WWISE_TOKEN:ro",
      "img:tag-base", "sh", "-c", "bash /work/bin/prewarm.sh"], container: "dev-prewarm-test") >> true
    1 * BuildContainer.system("docker", "commit", "dev-prewarm-test", "img:tag") >> true
    1 * BuildContainer.system("docker", "rm", "-f", "dev-prewarm-test",
      out: File::NULL, err: File::NULL) >> true
  end

  test "prewarm_commit! raises when the prewarm run fails, still removing the container" do
    Given "a prewarm command that fails"

    When "running the prewarm commit"
    BuildContainer.send(
      :prewarm_commit!, "img:tag-base", "img:tag",
      volumes: [], prewarm: "false", secrets: {}
    )

    Then "it surfaces the failure and the ensure block removes the container (no commit)"
    raises RuntimeError
    1 * BuildContainer.prewarm_container_name >> "dev-prewarm-test"
    1 * BuildContainer.write_secret_files({}) >> {}
    1 * BuildContainer.run_watched(["docker", "run", "--name", "dev-prewarm-test",
      "img:tag-base", "sh", "-c", "false"], container: "dev-prewarm-test") >> false
    1 * BuildContainer.system("docker", "rm", "-f", "dev-prewarm-test",
      out: File::NULL, err: File::NULL) >> true
  end

  test "write_secret_files writes each secret to a private temp file" do
    When "writing secret files"
    files = BuildContainer.send(:write_secret_files, { "TOK" => "s3cr3t" })

    Then "the value is on disk with owner-only permissions"
    File.read(files["TOK"]) == "s3cr3t"
    (File.stat(files["TOK"]).mode & 0o777) == 0o600

    Cleanup
    files.each_value { |p| File.delete(p) if File.exist?(p) }
  end

  test "service_container_name drops the registry and replaces the tag colon" do
    When "naming the service container for a full image:tag"
    name = BuildContainer.service_container_name("jpduchesne89/snappy-linux:content-abc123")

    Then "the name is registry-free, colon-free, and dev-prefixed"
    name == "dev-snappy-linux-content-abc123"
  end

  test "service_name_prefix is the tag-independent project prefix" do
    When "computing the reap prefix for a tag"
    prefix = BuildContainer.service_name_prefix("jpduchesne89/snappy-linux:content-abc123")

    Then "it omits the tag so any tag's container matches"
    prefix == "dev-snappy-linux-"
  end

  test "docker_exec_command targets the container with /project workdir" do
    When "building a docker exec command"
    cmd = BuildContainer.docker_exec_command(
      "dev-snappy-linux-content-abc", shell_cmd: "./bin/build.sh",
    )

    Then
    cmd[0] == "docker"
    cmd[1] == "exec"
    cmd.include?("-w")
    cmd.include?("/project")
    cmd.include?("dev-snappy-linux-content-abc")
    cmd.last(3) == ["sh", "-c", "./bin/build.sh"]
  end

  test "docker_exec_command renders env vars as -e flags before the container" do
    When "building a docker exec command with env"
    cmd = BuildContainer.docker_exec_command(
      "dev-snappy-linux-content-abc", shell_cmd: "./bin/build.sh",
      env: { "WWISE_TOKEN" => "tok-123" },
    )

    Then "the -e flag precedes the container name (a docker exec arg-order rule)"
    cmd.include?("WWISE_TOKEN=tok-123")
    cmd[cmd.index("WWISE_TOKEN=tok-123") - 1] == "-e"
    cmd.index("WWISE_TOKEN=tok-123") < cmd.index("dev-snappy-linux-content-abc")
  end

  test "ensure_service! creates the container when none exists" do
    Given "an image tag whose container is absent"
    tag = "jpduchesne89/snappy-linux:content-abc"

    When "ensuring the service"
    result = BuildContainer.ensure_service!(tag, project_root: Pathname("/proj"), volumes: ["/e:/e"])

    Then "stale containers are reaped, then the container is created (never started)"
    result == "dev-snappy-linux-content-abc"
    1 * BuildContainer.reap_stale_services!(tag) >> nil
    1 * BuildContainer.container_exists?("dev-snappy-linux-content-abc") >> false
    1 * BuildContainer.create_service_container("dev-snappy-linux-content-abc", tag,
      project_root: Pathname("/proj"), volumes: ["/e:/e"]) >> true
    0 * BuildContainer.start_container("dev-snappy-linux-content-abc")
  end

  test "ensure_service! starts the container when it exists but is stopped" do
    Given "an image tag whose container exists but is stopped"
    tag = "jpduchesne89/snappy-linux:content-abc"

    When "ensuring the service"
    BuildContainer.ensure_service!(tag, project_root: Pathname("/proj"))

    Then "the existing container is started, not recreated"
    1 * BuildContainer.reap_stale_services!(tag) >> nil
    1 * BuildContainer.container_exists?("dev-snappy-linux-content-abc") >> true
    1 * BuildContainer.container_running?("dev-snappy-linux-content-abc") >> false
    1 * BuildContainer.start_container("dev-snappy-linux-content-abc") >> true
    0 * BuildContainer.create_service_container("dev-snappy-linux-content-abc", tag,
      project_root: Pathname("/proj"), volumes: [])
  end

  test "ensure_service! is a no-op when the container is already running" do
    Given "an image tag whose container is already up"
    tag = "jpduchesne89/snappy-linux:content-abc"

    When "ensuring the service"
    BuildContainer.ensure_service!(tag, project_root: Pathname("/proj"))

    Then "neither start nor create is invoked"
    1 * BuildContainer.reap_stale_services!(tag) >> nil
    1 * BuildContainer.container_exists?("dev-snappy-linux-content-abc") >> true
    1 * BuildContainer.container_running?("dev-snappy-linux-content-abc") >> true
    0 * BuildContainer.start_container("dev-snappy-linux-content-abc")
  end

  test "reap_stale_services! removes other-tag containers but keeps the current tag" do
    Given "a current tag and a stale sibling container"
    tag = "jpduchesne89/snappy-linux:content-new"

    When "reaping"
    BuildContainer.send(:reap_stale_services!, tag)

    Then "only the non-current container is removed"
    1 * BuildContainer.service_containers("dev-snappy-linux-") >>
      ["dev-snappy-linux-content-old", "dev-snappy-linux-content-new"]
    1 * BuildContainer.remove_container("dev-snappy-linux-content-old") >> true
    0 * BuildContainer.remove_container("dev-snappy-linux-content-new")
  end

  test "reset_service! removes every container for the project prefix" do
    Given "two containers for the project (current and stale)"
    tag = "jpduchesne89/snappy-linux:content-abc"

    When "resetting"
    result = BuildContainer.reset_service!(tag)

    Then "all matching containers are removed and their names returned"
    result == ["dev-snappy-linux-content-old", "dev-snappy-linux-content-abc"]
    1 * BuildContainer.service_containers("dev-snappy-linux-") >>
      ["dev-snappy-linux-content-old", "dev-snappy-linux-content-abc"]
    1 * BuildContainer.remove_container("dev-snappy-linux-content-old") >> true
    1 * BuildContainer.remove_container("dev-snappy-linux-content-abc") >> true
  end

  test "create_service_container runs detached, mounts project + volumes, and idles" do
    Given "captured docker invocation"
    captured = nil

    When "creating the service container"
    BuildContainer.stubs(:system).with { |*argv, **_kw| captured = argv; true }.returns(true)
    BuildContainer.send(
      :create_service_container, "dev-x", "img:tag",
      project_root: Pathname("/project"), volumes: ["/engines/ue:/ue"],
    )

    Then "it is a detached, named run that bind-mounts the project + engine and sleeps"
    captured[0, 5] == ["docker", "run", "-d", "--name", "dev-x"]
    captured.include?("/project:/project")
    captured.include?("/engines/ue:/ue")
    captured.include?("img:tag")
    captured.last(2) == ["sleep", "infinity"]
  end

  test "create_service_container raises when docker run fails" do
    When "docker run fails"
    BuildContainer.stubs(:system).returns(false)
    BuildContainer.send(
      :create_service_container, "dev-x", "img:tag", project_root: Pathname("/project"),
    )

    Then
    raises RuntimeError
  end
end

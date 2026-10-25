# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/build_container"
require "dev/build_container_config"
require "dev/command"
require "dev/deps/dependency"
require "dev/deps/lockfile"
require "dev/dockerfile_image"
require "dev/engine_resources"
require "dev/environment_image"
require "dev/project_images"
require "pathname"
require "tmpdir"

# ProjectImages over a real temp checkout: deps.lock written by Lockfile,
# the dev.yml facts as the loader would hand them over.
transform!(RSpock::AST::Transformation)
class Dev::ProjectImagesTest < Minitest::Test
  include SorbetHelper

  # --- all / named --------------------------------------------------------

  test "all is the lock's image pins, in lock order, as images" do
    Given
    root = checkout(pins: [brew_pin, image_pin(name: "snappy-linux"), image_pin(name: "snappy-server")])

    When
    images = Dev::ProjectImages.new(root:).all

    Then
    images.map(&:class).uniq == [Dev::EnvironmentImage]
    images.map(&:name) == ["snappy-linux", "snappy-server"]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "all is empty for a project pinning no image" do
    Given
    root = checkout(pins: [brew_pin])

    Expect
    Dev::ProjectImages.new(root:).all == []

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "named finds an image by its block name, or lists what the lock pins" do
    Given
    root = checkout(pins: [image_pin(name: "snappy-linux"), image_pin(name: "snappy-server")])
    images = Dev::ProjectImages.new(root:)

    When
    error = assert_raises(Dev::ProjectImages::UnknownImageError) { images.named("snappy-srv") }

    Then
    images.named("snappy-server").name == "snappy-server"
    error.message.include?("snappy-srv")
    error.message.include?("snappy-linux, snappy-server")

    Cleanup
    FileUtils.rm_rf(root)
  end

  # --- for(cmd): the table ----------------------------------------------

  test "for(cmd) answers the command's environment from runs_on and the lock: #{why}" do
    Given
    root = checkout(pins: [brew_pin] + pinned.map { |pin_name| image_pin(name: pin_name) })
    cmd = Dev::ProjectCommand.new(run: "./bin/x.sh", runs_on: runs_on)

    When
    placement = Dev::ProjectImages.new(root:).for(cmd)

    Then
    (placement == :host ? :host : placement.name) == expected

    Cleanup
    FileUtils.rm_rf(root)

    Where
    why                                     | runs_on        | pinned       | expected
    "host, whatever the lock"               | "host"         | ["a", "b"]   | :host
    "a name the lock pins"                  | "b"            | ["a", "b"]   | "b"
    "absent, no pin: ai-flow, plans, dev"   | nil            | []           | :host
    "absent, one pin: cellbound-3d"         | nil            | ["a"]        | "a"
  end

  test "for(cmd) refuses a name the lock does not pin, listing what it does" do
    Given
    root = checkout(pins: [image_pin(name: "snappy-linux"), image_pin(name: "snappy-server")])
    cmd = Dev::ProjectCommand.new(run: "./bin/build.sh", runs_on: "snappy-srv")

    When
    Dev::ProjectImages.new(root:).for(cmd, name: "build")

    Then
    error = raises(Dev::ProjectImages::UnknownImageError)
    error.message.include?("`build` runs on `snappy-srv`")
    error.message.include?("snappy-linux, snappy-server")

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "for(cmd) with no runs_on and several pins is ambiguous: dev never guesses; both names and the key to add" do
    Given
    root = checkout(pins: [image_pin(name: "snappy-linux"), image_pin(name: "snappy-server")])
    cmd = Dev::ProjectCommand.new(run: "./bin/build.sh")

    When
    Dev::ProjectImages.new(root:).for(cmd, name: "build")

    Then
    error = raises(Dev::ProjectImages::AmbiguousEnvironmentImageError)
    error.message.include?("`build`")
    error.message.include?("snappy-linux, snappy-server")
    error.message.include?("runs_on:")

    Cleanup
    FileUtils.rm_rf(root)
  end

  # --- the scoped refusal (dev#307 §0) ---------------------------------

  test "a project whose lock pins an image refuses every retired key with its migration" do
    Given "a migrated lock and a dev.yml still on the old shape"
    root = checkout(pins: [image_pin])
    legacy_keys = [
      "build.container", "build.container.resources", "commands.deploy.container: false", "commands.build.container: true",
    ]
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89", persist: true,
      volumes: ["/e:/ue"], run_env: { "T" => "ns/t" })

    When
    Dev::ProjectImages.new(root:, build_container: config, legacy_keys:).all

    Then "one message, every key, each with where it goes"
    error = raises(Dev::ProjectImages::RetiredKeysError)
    error.message.include?("build.container.image")
    error.message.include?("build.container.persist")
    error.message.include?("persist true")
    error.message.include?("build.container.volumes")
    error.message.include?("volume ")
    error.message.include?("build.container.run_env")
    error.message.include?("run_env ")
    error.message.include?("build.container.resources")
    error.message.include?("`engine:`")
    error.message.include?("commands.deploy.container: false")
    error.message.include?("runs_on: host")
    error.message.include?("commands.build.container: true")

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a project whose lock pins no image keeps its retired keys: the legacy path, untouched until it migrates" do
    Given
    root = checkout(pins: [brew_pin], dockerfile: "FROM --platform=linux/amd64 ubuntu:24.04\n")
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")

    Expect
    Dev::ProjectImages.new(root:, build_container: config, legacy_keys: ["build.container"]).all == []

    Cleanup
    FileUtils.rm_rf(root)
  end

  # --- the legacy path (gone with dev#311) ------------------------------

  test "on the legacy path, for(cmd) is the Dockerfile image unless the command opted out: #{why}" do
    Given
    root = checkout(pins: [brew_pin], dockerfile: "FROM --platform=linux/amd64 ubuntu:24.04\n")
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89", persist: true)
    images = Dev::ProjectImages.new(root:, build_container: config, legacy_keys: ["build.container"])

    When
    placement = images.for(cmd)

    Then
    (placement == :host ? :host : [placement.class, placement.name, placement.persist]) == expected

    Cleanup
    FileUtils.rm_rf(root)

    Where
    why                          | cmd                                                           | expected
    "the default"                | Dev::ProjectCommand.new(run: "x")                             | [Dev::DockerfileImage, "snappy-linux", true]
    "container: false"           | Dev::ProjectCommand.new(run: "x", container: false)           | :host
    "runs_on: host, same thing"  | Dev::ProjectCommand.new(run: "x", runs_on: "host")            | :host
  end

  test "on the legacy path, a runs_on naming an image is refused: the lock pins none" do
    Given
    root = checkout(pins: [brew_pin], dockerfile: "FROM ubuntu:24.04\n")
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")

    When
    Dev::ProjectImages.new(root:, build_container: config, legacy_keys: ["build.container"])
      .for(Dev::ProjectCommand.new(run: "x", runs_on: "snappy-linux"), name: "build")

    Then
    error = raises(Dev::ProjectImages::UnknownImageError)
    error.message.include?("pins none")

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a container block naming no image, with no pin, is NoEnvironmentImageError pointing at the block" do
    Given "the half-migrated shape: the block shapes a container around an image that is nowhere"
    root = checkout(pins: [brew_pin])
    config = Dev::BuildContainerConfig.new(persist: true)

    When
    Dev::ProjectImages.new(root:, build_container: config, legacy_keys: ["build.container"]).for(Dev::ProjectCommand.new(run: "x"))

    Then
    error = raises(Dev::ProjectImages::NoEnvironmentImageError)
    error.message.include?("`image` block")
    error.message.include?("dev deps update")

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "containerized? is whether any command could run in a container: a pin, or the legacy image" do
    Given
    pinned = checkout(pins: [image_pin])
    legacy = checkout(pins: [brew_pin], dockerfile: "FROM ubuntu:24.04\n")
    plain = checkout(pins: [brew_pin])
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")

    Expect
    Dev::ProjectImages.new(root: pinned).containerized?
    Dev::ProjectImages.new(root: legacy, build_container: config, legacy_keys: ["build.container"]).containerized?
    !Dev::ProjectImages.new(root: plain).containerized?

    Cleanup
    [pinned, legacy, plain].each { |dir| FileUtils.rm_rf(dir) }
  end

  # --- ensure! ------------------------------------------------------------

  test "ensure! resolves a pinned image through ensure_environment_image! with the project's engine hint" do
    Given
    root = checkout(pins: [image_pin])
    engine = Dev::EngineResources::Hint.new(cpus: 12)
    images = Dev::ProjectImages.new(root:, engine:)
    client = typed_mock(Dev::BuildContainer)
    client.expects(:ensure_environment_image!).once
      .with { |image, publish:, resources:| image.name == "snappy-linux" && publish == true && resources.cpus == 12 }
      .returns("the-ref")

    When
    result = images.ensure!(images.named("snappy-linux"), client:, publish: true)

    Then
    result == "the-ref"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "ensure! on the legacy path hands the block to ensure_image!, publish and the hint through, never pushing on its own" do
    Given
    root = checkout(pins: [brew_pin], dockerfile: "FROM ubuntu:24.04\n")
    engine = Dev::EngineResources::Hint.new(cpus: 12)
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")
    images = Dev::ProjectImages.new(root:, build_container: config, legacy_keys: ["build.container"], engine:)
    client = typed_mock(Dev::BuildContainer)
    client.expects(:ensure_image!).once
      .with do |cfg, project_root:, push:, publish:, resources:, **|
        cfg == config && project_root == root && !push && !publish && resources == engine
      end
      .returns("legacy-ref")

    When
    result = images.ensure!(images.for(Dev::ProjectCommand.new(run: "x")), client:, publish: false)

    Then
    result == "legacy-ref"

    Cleanup
    FileUtils.rm_rf(root)
  end

  private

  def checkout(pins:, dockerfile: nil)
    root = Pathname(Dir.mktmpdir("project-images"))
    Dev::Deps::Lockfile.new(dir: root).lock(Dev::EnvironmentImage.stamp(pins))
    (root / "Dockerfile").write(dockerfile) if dockerfile
    root
  end

  def image_pin(name: "snappy-linux", platform: "linux/amd64")
    Dev::Deps::Dependency.new(
      name: name, integration: :image, group: :app, version: "ue5.8-3", hash: "SHA256=#{"a" * 64}",
      metadata: {
        "from" => "ghcr.io/d3mlabs/unreal-engine-build-base", "platform" => platform, "platforms" => [platform],
        "registry" => "ghcr.io/d3mlabs", "apt" => ["dos2unix"],
      },
    )
  end

  def brew_pin
    Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build, version: "3.31", hash: "SHA256=0", metadata: {})
  end
end

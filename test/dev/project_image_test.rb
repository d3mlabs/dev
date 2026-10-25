# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/build_container"
require "dev/build_container_config"
require "dev/deps/dependency"
require "dev/deps/lockfile"
require "dev/environment_image"
require "dev/project_image"
require "pathname"
require "tmpdir"

# ProjectImage over a real temp checkout: deps.lock written by Lockfile,
# the build.container block as the loader would hand it over.
transform!(RSpock::AST::Transformation)
class Dev::ProjectImageTest < Minitest::Test
  include SorbetHelper

  test "one image pin is the project's image, with or without a container block" do
    Given
    root = checkout(pins: [image_pin])

    When
    image = Dev::ProjectImage.new(root:, config: nil).environment_image

    Then
    image.is_a?(Dev::EnvironmentImage)
    image.name == "snappy-linux"
    image.ref.start_with?("ghcr.io/d3mlabs/snappy-linux:")

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "an image pin wins over build.container.image/registry, which are then said to be ignored" do
    Given "a project half-migrated: the block still names the old image"
    root = checkout(pins: [image_pin])
    project = Dev::ProjectImage.new(root:, config: dockerfile_config)

    When
    image = nil
    _out, err = capture_io { image = project.environment_image }

    Then
    image.name == "snappy-linux"
    err.include?("build.container.image")
    err.include?("ignored")

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "no image pin and a block naming a Dockerfile image is the deprecated path: nil, the caller's config stands" do
    Given
    root = checkout(pins: [brew_pin])

    Expect
    Dev::ProjectImage.new(root:, config: dockerfile_config).environment_image.nil?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "no image pin and nothing naming a Dockerfile image is NoEnvironmentImageError, pointing at the block: #{why}" do
    Given
    root = checkout(pins: [brew_pin])

    When
    Dev::ProjectImage.new(root:, config:).environment_image

    Then
    error = raises(Dev::ProjectImage::NoEnvironmentImageError)
    error.message.include?("`image` block")
    error.message.include?("dev deps update")

    Cleanup
    FileUtils.rm_rf(root)

    Where
    why                        | config
    "no container block"       | nil
    "a block naming no image"  | Dev::BuildContainerConfig.new(persist: true)
  end

  test "several image pins are AmbiguousEnvironmentImageError naming them and d3mlabs/dev#307" do
    Given
    root = checkout(pins: [image_pin(name: "snappy-linux"), image_pin(name: "snappy-win")])

    When
    Dev::ProjectImage.new(root:, config: nil).environment_image

    Then
    error = raises(Dev::ProjectImage::AmbiguousEnvironmentImageError)
    error.message.include?("snappy-linux")
    error.message.include?("snappy-win")
    error.message.include?("d3mlabs/dev#307")

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "ref is the pin's ref, or the deprecated content tag when the block names a Dockerfile image" do
    Given
    pinned = checkout(pins: [image_pin])
    legacy = checkout(pins: [brew_pin], dockerfile: "FROM ubuntu:24.04\n")

    Expect
    Dev::ProjectImage.new(root: pinned, config: nil).ref == Dev::EnvironmentImage.from_pin(stamped(image_pin)).ref
    Dev::ProjectImage.new(root: legacy, config: dockerfile_config).ref.start_with?("jpduchesne89/snappy-linux:content-")

    Cleanup
    FileUtils.rm_rf(pinned)
    FileUtils.rm_rf(legacy)
  end

  test "ensure! resolves a pinned image through ensure_environment_image! with the project's engine hint" do
    Given
    root = checkout(pins: [image_pin])
    engine = Dev::EngineResources::Hint.new(cpus: 12)
    config = Dev::BuildContainerConfig.new(persist: true)
    client = typed_mock(Dev::BuildContainer)
    client.expects(:ensure_environment_image!).once
      .with { |image, publish:, resources:| image.name == "snappy-linux" && publish == true && resources.cpus == 12 }
      .returns("the-ref")

    When
    result = Dev::ProjectImage.new(root:, config:, engine:).ensure!(client:, publish: true)

    Then
    result == "the-ref"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "ensure! on the deprecated path hands the block to ensure_image!, publish through, never pushing on its own" do
    Given
    root = checkout(pins: [brew_pin])
    client = typed_mock(Dev::BuildContainer)
    client.expects(:ensure_image!).once
      .with { |config, project_root:, push:, publish:, **| config.image == "snappy-linux" && project_root == root && !push && !publish }
      .returns("legacy-ref")

    When
    result = Dev::ProjectImage.new(root:, config: dockerfile_config).ensure!(client:, publish: false)

    Then
    result == "legacy-ref"

    Cleanup
    FileUtils.rm_rf(root)
  end

  private

  def checkout(pins:, dockerfile: nil)
    root = Pathname(Dir.mktmpdir("project-image"))
    Dev::Deps::Lockfile.new(dir: root).lock(pins.map { |pin| stamped(pin) })
    (root / "Dockerfile").write(dockerfile) if dockerfile
    root
  end

  def stamped(pin)
    Dev::EnvironmentImage.stamp([pin]).first
  end

  def dockerfile_config
    Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")
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

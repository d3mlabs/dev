# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/build_container"
require "dev/build_container_config"
require "dev/engine_resources_check"
require "dev/environment_image"
require "support/fake_container_engine"
require "support/fake_registry_login"
require "tmpdir"

# BuildContainer#ensure_environment_image!: the generated image (dev#277)
# resolved local → (publisher: manifest) → pull → build → push, with the
# registry entered once around whatever touches it.
transform!(RSpock::AST::Transformation)
class Dev::BuildContainerEnvironmentTest < Minitest::Test
  include SorbetHelper

  test "a local hit is answered without entering the registry" do
    Given
    engine = engine_where(local: true)
    login = FakeRegistryLogin.new
    bc = build_container(engine:, login:)

    When
    result = bc.ensure_environment_image!(image)

    Then "one inspect, no login — the image is here, nothing else to ask"
    result == image.ref
    engine.runs == [["image", "inspect", image.ref]]
    login.sessions.empty?
  end

  test "a publisher with a local hit enters the registry with write scope and pushes what it has" do
    Given
    engine = engine_where(local: true, in_registry: false)
    login = FakeRegistryLogin.new
    bc = build_container(engine:, login:)

    When
    result = bc.ensure_environment_image!(image, publish: true)

    Then
    result == image.ref
    login.sessions == [["ghcr.io", true]]
    engine.runs == [["image", "inspect", image.ref], ["manifest", "inspect", image.ref], ["push", image.ref]]
  end

  test "a publisher without the image pulls it like anyone else; a pull hit is the registry's copy and pushes nothing" do
    Given
    engine = engine_where(local: false, in_registry: true, pull: true)
    bc = build_container(engine:, login: FakeRegistryLogin.new)

    When
    result = bc.ensure_environment_image!(image, publish: true)

    Then "no manifest shortcut: publishing is pushing the digest you built or found"
    result == image.ref
    engine.runs == [["image", "inspect", image.ref], ["pull", image.ref]]
  end

  test "a pull hit enters the registry with read scope and pulls the ref" do
    Given
    engine = engine_where(local: false, pull: true)
    login = FakeRegistryLogin.new
    bc = build_container(engine:, login:)

    When
    result = bc.ensure_environment_image!(image)

    Then
    result == image.ref
    login.sessions == [["ghcr.io", false]]
    engine.runs == [["image", "inspect", image.ref], ["pull", image.ref]]
  end

  test "a pull miss builds the generated Dockerfile from a temp dir with an empty context and the digest as a build arg" do
    Given
    seen = {}
    read_dockerfile = ->(argv) { seen[:dockerfile] = File.read(argv[argv.index("-f") + 1]) }
    engine = engine_where(local: false, pull: false, &read_dockerfile)
    bc = build_container(engine:, login: FakeRegistryLogin.new)

    When
    result = bc.ensure_environment_image!(image)
    build = engine.runs.fetch(2)
    context = build.last

    Then "the Dockerfile the digest was computed over is the one built, nothing else in the context"
    result == image.ref
    engine.runs.map(&:first) == ["image", "pull", "build"]
    build.first(6) == ["build", "--progress=plain", "--platform", "linux/amd64", "-t", image.ref]
    build.include?("--build-arg") && build[build.index("--build-arg") + 1] == "DEV_ENVIRONMENT_DIGEST=#{image.digest}"
    build[build.index("-f") + 1] == File.join(context, "Dockerfile")
    seen[:dockerfile] == image.dockerfile
    !File.exist?(context)
  end

  test "a publisher that had to build pushes the fresh image without asking the registry" do
    Given
    engine = engine_where(local: false, in_registry: false, pull: false)
    bc = build_container(engine:, login: FakeRegistryLogin.new)

    When
    bc.ensure_environment_image!(image, publish: true)

    Then "a pull miss already said the registry lacks the tag"
    engine.runs.map(&:first) == ["image", "pull", "build", "push"]
  end

  test "a failed build is an error naming the ref" do
    Given
    engine = engine_where(local: false, pull: false, build: false)
    bc = build_container(engine:, login: FakeRegistryLogin.new)

    When
    bc.ensure_environment_image!(image)

    Then
    error = raises(Dev::BuildContainer::BuildFailedError)
    error.message.include?(image.ref)
  end

  test "the engine's resources are checked against the hint before any image work" do
    Given
    engine = engine_where(local: true)
    resources = Dev::EngineResources::Hint.new(cpus: 12, memory_gib: 24)
    check = typed_mock(Dev::EngineResourcesCheck)
    check.expects(:check!).once.with(engine: engine, hint: resources)
      .raises(Dev::EngineResourcesCheck::UndersizedEngineError, "4 cpus")
    bc = Dev::BuildContainer.new(engine: engine, resources_check: check, registry_login: FakeRegistryLogin.new)

    When
    bc.ensure_environment_image!(image, resources: resources)

    Then
    raises Dev::EngineResourcesCheck::UndersizedEngineError
    engine.runs.empty?
  end

  test "the Dockerfile path is deprecated: ensure_image! says so on stderr and names the image block" do
    Given
    dir = Dir.mktmpdir("build-container-test-")
    File.write(File.join(dir, "Dockerfile"), "FROM ubuntu:24.04")
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")
    bc = build_container(engine: engine_where(local: true), login: FakeRegistryLogin.new)

    When
    _out, err = capture_io { bc.ensure_image!(config, project_root: Pathname(dir)) }

    Then
    err.include?("deprecated")
    err.include?("image")
    err.include?("d3mlabs/dev#311")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  private

  def image(apt: ["dos2unix"])
    Dev::EnvironmentImage.new(
      name: "snappy-linux", from: "ghcr.io/d3mlabs/unreal-engine-build-base", from_digest: "a" * 64,
      platform: "linux/amd64", apt:, registry: "ghcr.io/d3mlabs",
    )
  end

  def build_container(engine:, login:)
    Dev::BuildContainer.new(engine: engine, registry_login: login)
  end

  # Scripts the engine's answers per docker verb; the block sees each build's argv
  # while its temp context still exists. A lambda, not a block: under RSpock's
  # AST transform a `|argv|` block has its one Array argument splatted.
  def engine_where(local: false, in_registry: false, pull: true, build: true, push: true, &on_build)
    handler = lambda do |argv|
      case argv.first(2)
      when ["image", "inspect"] then local
      when ["manifest", "inspect"] then in_registry
      else answer_verb(argv, pull:, build:, push:, &on_build)
      end
    end
    FakeContainerEngine.new(&handler)
  end

  def answer_verb(argv, pull:, build:, push:)
    case argv.first
    when "pull" then pull
    when "build"
      yield(argv) if block_given?
      build
    when "push" then push
    else true
    end
  end
end

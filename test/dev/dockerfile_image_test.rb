# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/build_container"
require "dev/build_container_config"
require "dev/credentials"
require "dev/dockerfile_image"
require "dev/engine_resources"
require "pathname"
require "tmpdir"

# The deprecated Dockerfile image (d3mlabs/dev#311) wearing the reader
# surface of an EnvironmentImage, over a real checkout.
transform!(RSpock::AST::Transformation)
class Dev::DockerfileImageTest < Minitest::Test
  include SorbetHelper

  test "it reads as its block: name, the container's shape, the content-addressed ref" do
    Given
    root = checkout("FROM --platform=linux/amd64 ubuntu:24.04\n")
    config = Dev::BuildContainerConfig.new(
      image: "snappy-linux", registry: "jpduchesne89", persist: true, volumes: ["/e:/ue"], run_env: { "T" => "ns/t" },
    )

    When
    image = Dev::DockerfileImage.new(root:, config:)

    Then
    image.name == "snappy-linux"
    image.persist == true
    image.volumes == ["/e:/ue"]
    image.run_env == { "T" => "ns/t" }
    image.ref.start_with?("jpduchesne89/snappy-linux:content-")
    image.ref == Dev::BuildContainer.image_with_tag(config, project_root: root)

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "dev_platform is the Dockerfile's first FROM --platform, or nil when it declares none: #{why}" do
    Given
    root = checkout(dockerfile)
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")

    Expect
    Dev::DockerfileImage.new(root:, config:).dev_platform == expected

    Cleanup
    FileUtils.rm_rf(root)

    Where
    why                   | dockerfile                                    | expected
    "a literal platform"  | "FROM --platform=linux/amd64 ubuntu:24.04\n"  | "linux-x86_64"
    "no platform"         | "FROM ubuntu:24.04\n"                         | nil
  end

  test "ensure! hands the block to ensure_image! with lazy credential providers, publish and the hint through" do
    Given
    root = checkout("FROM ubuntu:24.04\n")
    engine = Dev::EngineResources::Hint.new(cpus: 12)
    config = Dev::BuildContainerConfig.new(
      image: "snappy-linux", registry: "jpduchesne89", build_args: { "A" => "ns/a" }, build_secrets: { "S" => "ns/s" },
    )
    Dev::Credentials.stubs(:resolve_build_args).with({ "A" => "ns/a" }).returns({ "A" => "arg" })
    Dev::Credentials.stubs(:resolve_build_args).with({ "S" => "ns/s" }).returns({ "S" => "secret" })
    client = typed_mock(Dev::BuildContainer)
    client.expects(:ensure_image!).once
      .with do |cfg, project_root:, push:, publish:, build_args_provider:, secrets_provider:, resources:|
        cfg == config && project_root == root && !push && publish && resources == engine &&
          build_args_provider.call == { "A" => "arg" } && secrets_provider.call == { "S" => "secret" }
      end
      .returns("legacy-ref")

    When
    result = Dev::DockerfileImage.new(root:, config:).ensure!(client:, publish: true, resources: engine)

    Then
    result == "legacy-ref"

    Cleanup
    FileUtils.rm_rf(root)
  end

  private

  def checkout(dockerfile)
    root = Pathname(Dir.mktmpdir("dockerfile-image"))
    (root / "Dockerfile").write(dockerfile)
    root
  end
end

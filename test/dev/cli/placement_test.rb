# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/dependency"
require "dev/environment_image"
require "dev/cli/placement"

transform!(RSpock::AST::Transformation)
class Dev::Cli::PlacementTest < Minitest::Test
  test "the host placement is named `host` and equals any other" do
    Given
    host = Dev::Cli::Placement::Host.new

    Expect
    host.name == "host"
    host == Dev::Cli::Placement::Host.new
    host.hash == Dev::Cli::Placement::Host.new.hash
    host != "host"
  end

  test "an image placement is named after its image and equal by the image's identity" do
    Given
    linux = image(name: "snappy-linux")
    same = image(name: "snappy-linux")
    drifted = image(name: "snappy-linux", apt: ["libnss3"])
    server = image(name: "snappy-server")
    placement = Dev::Cli::Placement::Image.new(image: linux)

    Expect
    placement.name == "snappy-linux"
    placement.image.equal?(linux)
    placement == Dev::Cli::Placement::Image.new(image: same)
    placement.hash == Dev::Cli::Placement::Image.new(image: same).hash
    placement != Dev::Cli::Placement::Image.new(image: drifted)
    placement != Dev::Cli::Placement::Image.new(image: server)
    placement != Dev::Cli::Placement::Host.new
  end

  private

  def image(name:, apt: ["dos2unix"])
    Dev::EnvironmentImage.from_pin(
      Dev::Deps::Dependency.new(
        name: name, integration: :image, group: :app, version: "ue5.8-3", hash: "SHA256=#{"a" * 64}",
        metadata: {
          "from" => "ghcr.io/d3mlabs/unreal-engine-build-base", "platform" => "linux/amd64",
          "platforms" => ["linux/amd64"], "registry" => "ghcr.io/d3mlabs", "apt" => apt,
        },
      ),
    )
  end
end

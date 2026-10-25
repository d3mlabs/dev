# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/host_environment"
require "dev/environment_image"
require "dev/deps/dependency"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::HostEnvironmentTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("host-env")
    @marker = File.join(@dir, "environment")
  end

  def teardown
    FileUtils.rm_rf(@dir)
    super
  end

  test "a host with no marker was provisioned from nothing" do
    Given
    env = Dev::HostEnvironment.new(path: @marker)

    Expect
    env.name.nil?
    env.digest.nil?
    !env.provisioned_from?(image)
  end

  test "the marker the image build wrote names the image and its digest" do
    Given "exactly what EnvironmentImage#dockerfile printf's"
    File.write(@marker, image.marker)
    env = Dev::HostEnvironment.new(path: @marker)

    Expect
    env.name == "snappy-linux"
    env.digest == image.digest
    env.provisioned_from?(image)
  end

  test "a marker is one image, not a name or a digest alone: #{what}" do
    Given
    File.write(@marker, image.marker)
    env = Dev::HostEnvironment.new(path: @marker)

    Expect "another digest under the same name, or the same recipe under another name, both fail"
    !env.provisioned_from?(image(name: name, apt: apt))

    Where
    what                | name            | apt
    "a drifted recipe"  | "snappy-linux"  | ["libnss3"]
    "a different image" | "snappy-server" | ["dos2unix"]
  end

  test "a malformed marker is no marker: #{what}" do
    Given
    File.write(@marker, text)
    env = Dev::HostEnvironment.new(path: @marker)

    Expect
    env.name.nil?
    env.digest.nil?
    !env.provisioned_from?(image)

    Where
    what                      | text
    "empty"                   | ""
    "a name only"             | "name=snappy-linux\n"
    "a digest only"           | "digest=#{"a" * 64}\n"
    "a digest that is no hex" | "name=snappy-linux\ndigest=not-a-digest\n"
    "something else"          | "FROM ubuntu\n"
  end

  test "a short form of the identity for messages: name@12 hex, or 'nothing' with no marker" do
    Given
    File.write(@marker, image.marker)

    Expect
    Dev::HostEnvironment.new(path: @marker).describe == "snappy-linux@#{image.digest[0, 12]}"
    Dev::HostEnvironment.new(path: File.join(@dir, "absent")).describe == "no image (no #{File.join(@dir, "absent")})"
  end

  test "the default path is the marker the image build writes" do
    Expect
    Dev::HostEnvironment::MARKER_PATH == Dev::EnvironmentImage::MARKER_PATH
    Dev::HostEnvironment::MARKER_PATH == "/etc/dev/environment"
  end

  private

  def image(name: "snappy-linux", apt: ["dos2unix"])
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

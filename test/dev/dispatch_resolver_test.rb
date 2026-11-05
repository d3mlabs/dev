# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/dependency"
require "dev/dispatch"
require "dev/dispatch_resolver"
require "dev/environment_image"
require "dev/host_environment"
require "dev/host_rule"
require "dev/placement"
require "fileutils"
require "pathname"
require "tmpdir"

# The one decision site of where a verb runs, against a real host marker
# in a temp dir: `/etc/dev/environment` is what the host rule reads, so
# each case writes (or leaves absent) the marker that makes it so.
transform!(RSpock::AST::Transformation)
class Dev::DispatchResolverTest < Minitest::Test
  # On the class: Where cells are evaluated there.
  class << self
    def image(name: "cellbound-3d-linux", apt: ["dos2unix"])
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

  def setup
    @dir = Pathname(Dir.mktmpdir("dispatch-resolver"))
    @marker = (@dir / "environment").to_s
  end

  def teardown
    FileUtils.rm_rf(@dir)
    super
  end

  # The same image for the test bodies, which run on the instance.
  def image(name: "cellbound-3d-linux", apt: ["dos2unix"])
    self.class.image(name: name, apt: apt)
  end

  def resolver(inside_container: false)
    host_rule = Dev::HostRule.new(
      host_environment: Dev::HostEnvironment.new(path: @marker), inside_container: inside_container,
    )
    Dev::DispatchResolver.new(host_rule: host_rule)
  end

  test "a build placed on the host is native wherever dev runs" do
    Expect
    resolver.resolve(Dev::Placement::Host.new, subject: "rspock") == Dev::Dispatch::Native.new
  end

  test "a build placed in an image is native exactly when the host rule passes: #{what}" do
    Given
    File.write(@marker, marker_text) if marker_text
    placement = Dev::Placement::Image.new(image: image)

    Expect
    resolver(inside_container: inside).resolve(placement, subject: "cellbound-3d-win64-dev") == Dev::Dispatch::Native.new

    Where
    what                                | marker_text  | inside
    "a host provisioned from the image" | image.marker | false
    "inside a container of the image"   | image.marker | true
  end

  test "a host not provisioned from the image has no dispatch yet: refused, naming the build, the image and the fix" do
    Given "a bare host (no marker)"
    placement = Dev::Placement::Image.new(image: image)

    When
    resolver.resolve(placement, subject: "cellbound-3d-win64-dev")

    Then
    error = raises(Dev::DispatchResolver::RemoteDispatchUnavailableError)
    error.message.include?("`cellbound-3d-win64-dev` builds in cellbound-3d-linux")
    error.message.include?("this host was not provisioned from it")
    error.message.include?("provisioned from cellbound-3d-linux")
  end

  test "a host provisioned from another image is not this image's host either" do
    Given
    File.write(@marker, image(name: "snappy-linux").marker)

    When
    resolver.resolve(Dev::Placement::Image.new(image: image), subject: "cellbound-3d-win64-dev")

    Then
    raises Dev::DispatchResolver::RemoteDispatchUnavailableError
  end

  test "inside a container that is not the image's, the work is drift, refused as the command runner refuses it" do
    Given "a container made from a drifted recipe of the image"
    File.write(@marker, image(apt: ["libnss3"]).marker)

    When
    resolver(inside_container: true).resolve(Dev::Placement::Image.new(image: image), subject: "cellbound-3d-win64-dev")

    Then
    raises Dev::HostRule::ContainerDriftError
  end
end

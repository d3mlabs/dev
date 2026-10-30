# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/host_rule"
require "dev/host_environment"
require "dev/environment_image"
require "dev/deps/dependency"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::HostRuleTest < Minitest::Test
  # On the class: Where cells are evaluated there.
  class << self
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

  def setup
    @dir = Pathname(Dir.mktmpdir("host-rule"))
    @marker = (@dir / "environment").to_s
  end

  def teardown
    FileUtils.rm_rf(@dir)
    super
  end

  test "a pinned image's work runs here exactly when this host was provisioned from it: #{what}" do
    Given
    File.write(@marker, marker_text) if marker_text
    host = rule

    Expect
    host.native?(image) == native

    Where
    what                              | marker_text                        | native
    "no marker, even on its platform" | nil                                | false
    "the lock's image"                | image.marker                       | true
    "a drifted recipe"                | image(apt: ["libnss3"]).marker     | false
    "another image"                   | image(name: "snappy-server").marker | false
  end

  test "why a host is native, for the up report" do
    Given
    File.write(@marker, image.marker)

    Expect
    rule.why_native(image) == "this host was provisioned from snappy-linux@#{image.digest[0, 12]}"
  end

  test "drift is a marker that names the image under another digest — not an absent marker, not another image" do
    Given
    File.write(@marker, image(apt: ["libnss3"]).marker)
    host = rule

    Expect
    host.host == "snappy-linux@#{image(apt: ["libnss3"]).digest[0, 12]}"
    host.drifted?(image)
    !host.drifted?(image(name: "snappy-server"))
    !rule(marker: (@dir / "absent").to_s).drifted?(image)
  end

  test "inside a container of the lock's image, the image's work is current" do
    Given
    File.write(@marker, image.marker)

    When
    rule.assert_container_is!(image)

    Then "no error"
    true
  end

  test "inside a container that is not the lock's image, the work is refused with both identities and the way out: #{what}" do
    Given
    File.write(@marker, marker_text) if marker_text
    host = rule
    error = assert_raises(Dev::HostRule::ContainerDriftError) { host.assert_container_is!(image) }

    Expect
    error.message.include?("this container is #{inside}")
    error.message.include?("the lock's snappy-linux is snappy-linux@#{image.digest[0, 12]}")
    error.message.include?("dev container reset && dev up")

    Where
    what                | marker_text                         | inside
    "a drifted recipe"  | image(apt: ["libnss3"]).marker      | "snappy-linux@#{image(apt: ["libnss3"]).digest[0, 12]}"
    "another image"     | image(name: "snappy-server").marker | "snappy-server@#{image(name: "snappy-server").digest[0, 12]}"
    "no marker at all"  | nil                                 | "no image"
  end

  test "a container's pins are current when the one the marker names carries the marker's digest: #{what}" do
    Given
    File.write(@marker, marker_text)
    pins = [image, image(name: "snappy-server")]

    Expect
    raised = begin
      rule.assert_container_current!(pins)
      false
    rescue Dev::HostRule::ContainerDriftError
      true
    end
    raised == drift

    Where
    what                                  | marker_text                                   | drift
    "the marker is one of the pins"       | image.marker                                  | false
    "the marker names a pin, old digest"  | image(apt: ["libnss3"]).marker                | true
    "the marker names no pin"             | image(name: "other", apt: ["x"]).marker       | false
  end

  private

  def image(name: "snappy-linux", apt: ["dos2unix"])
    self.class.image(name: name, apt: apt)
  end

  def rule(marker: @marker)
    Dev::HostRule.new(host_environment: Dev::HostEnvironment.new(path: marker))
  end
end

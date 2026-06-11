# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/build_container_config"

transform!(RSpock::AST::Transformation)
class Dev::BuildContainerConfigTest < Minitest::Test
  test "image_ref combines registry and image" do
    When "creating a config"
    config = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")

    Then
    config.image_ref == "jpduchesne89/snappy-linux"
  end

  test "equality compares image and registry" do
    Given "two identical configs"
    a = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")
    b = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")

    Expect
    a == b
    a.eql?(b)
    a.hash == b.hash
  end

  test "inequality when image differs" do
    Given "two configs with different images"
    a = Dev::BuildContainerConfig.new(image: "snappy-linux", registry: "jpduchesne89")
    b = Dev::BuildContainerConfig.new(image: "cellbound-linux", registry: "jpduchesne89")

    Expect
    a != b
  end
end

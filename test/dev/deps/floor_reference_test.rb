# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/floor_reference"

transform!(RSpock::AST::Transformation)
class Dev::Deps::FloorReferenceTest < Minitest::Test
  test "parse reads <host>/<repository>:<tag> into its parts: #{source}" do
    When
    ref = Dev::Deps::FloorReference.parse(source)

    Then
    ref.host == host
    ref.repository == repository
    ref.tag == tag
    ref.to_s == source

    Where
    source                                             | host                   | repository                         | tag
    "ghcr.io/d3mlabs/unreal-engine-build-base:ue5.8-3" | "ghcr.io"              | "d3mlabs/unreal-engine-build-base" | "ue5.8-3"
    "localhost:5000/base:latest"                       | "localhost:5000"       | "base"                             | "latest"
    "registry.example.com/a/b/c:v1.2_3"                | "registry.example.com" | "a/b/c"                            | "v1.2_3"
  end

  test "name is the image less its tag, registry everything before the repository's last segment: #{source}" do
    Expect
    Dev::Deps::FloorReference.parse(source).name == name
    Dev::Deps::FloorReference.parse(source).registry == registry

    Where
    source                                             | name                                       | registry
    "ghcr.io/d3mlabs/unreal-engine-build-base:ue5.8-3" | "ghcr.io/d3mlabs/unreal-engine-build-base" | "ghcr.io/d3mlabs"
    "ghcr.io/base:1"                                   | "ghcr.io/base"                             | "ghcr.io"
    "registry.example.com/a/b/c:v1"                    | "registry.example.com/a/b/c"               | "registry.example.com/a/b"
  end

  test "a source that is not <host>/<repository>:<tag> is a ReferenceError naming the shape to declare: #{why}" do
    When
    Dev::Deps::FloorReference.parse(source)

    Then
    error = raises Dev::Deps::FloorReference::ReferenceError
    error.message.include?("<registry>/<repository>:<tag>")
    error.message.include?(source.inspect)

    Where
    why                                                        | source
    "no registry host: the floor is never a floating Hub name" | "ubuntu:22.04"
    "no tag: nothing to resolve"                               | "ghcr.io/d3mlabs/unreal-engine-build-base"
    "a digest is already resolved; declare the tag"            | "ghcr.io/d3mlabs/unreal-engine-build-base@sha256:abc"
    "a typo'd tag separator"                                   | "ghcr.io/d3mlabs/unreal-engine-build-base;ue5.8-3"
    "no source at all"                                         | nil
    "nothing"                                                  | ""
  end

  test "two references to the same floor are equal and hash alike; another tag is another floor" do
    Given
    one = Dev::Deps::FloorReference.parse("ghcr.io/d3mlabs/base:v1")
    same = Dev::Deps::FloorReference.new(host: "ghcr.io", repository: "d3mlabs/base", tag: "v1")
    other = Dev::Deps::FloorReference.parse("ghcr.io/d3mlabs/base:v2")

    Expect
    one == same
    one.eql?(same)
    one.hash == same.hash
    one != other
    { one => :a }.key?(same)
  end
end

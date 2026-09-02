# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/package_version"

transform!(RSpock::AST::Transformation)
class Dev::Deps::PackageVersionTest < Minitest::Test
  test "a bare version defaults every optional fact to its empty form" do
    Given "a version with no platform, digest, artifact, or edge facts"
    version = Dev::Deps::PackageVersion.new(version: "1.2.3")

    Expect "absence is modeled as absence — empty collections and nil digest"
    version.version == "1.2.3"
    version.platforms == []
    version.digest.nil?
    version.artifacts == {}
    version.dependencies == []
  end

  test "carries the full fact set when the universe provides one" do
    Given "a version with platforms, digest, per-platform artifacts, and edges"
    artifact = Dev::Deps::Artifact.new(uri: "https://example.com/sml-linux.zip", digest: "SHA256=abc")
    edge = Dev::Deps::DependencyEdge.new(name: "SML", constraint: "^3.0.0")
    version = Dev::Deps::PackageVersion.new(
      version: "3.12.0",
      platforms: ["Windows", "LinuxServer"],
      digest: "SHA256=fff",
      artifacts: { "LinuxServer" => artifact },
      dependencies: [edge],
    )

    Expect
    version.platforms == ["Windows", "LinuxServer"]
    version.digest == "SHA256=fff"
    version.artifacts["LinuxServer"] == artifact
    version.dependencies == [edge]
  end

  test "collection facts are frozen at construction" do
    Given "a version built from mutable collections"
    version = Dev::Deps::PackageVersion.new(
      version: "1.0.0",
      platforms: ["Windows"],
      artifacts: { "Windows" => Dev::Deps::Artifact.new(uri: "https://example.com/a.zip") },
      dependencies: [Dev::Deps::DependencyEdge.new(name: "x", constraint: nil)],
    )

    Expect "none of them can be mutated after the fact"
    version.platforms.frozen?
    version.artifacts.frozen?
    version.dependencies.frozen?
  end

  test "mutating the arrays it was built from cannot change it" do
    Given "collections handed to the constructor and then mutated"
    platforms = ["Windows"]
    version = Dev::Deps::PackageVersion.new(version: "1.0.0", platforms: platforms)

    When "the caller mutates its own array afterwards"
    platforms << "LinuxServer"

    Then "the version's facts are unaffected"
    version.platforms == ["Windows"]
  end

  test "is value-equal" do
    Given "two versions built from the same facts"
    a = Dev::Deps::PackageVersion.new(version: "1.0.0", digest: "SHA256=aaa")
    b = Dev::Deps::PackageVersion.new(version: "1.0.0", digest: "SHA256=aaa")

    Expect
    a == b
    a.hash == b.hash
  end

  test "differing facts are not equal" do
    Given "two versions that differ only in digest"
    a = Dev::Deps::PackageVersion.new(version: "1.0.0", digest: "SHA256=aaa")
    b = Dev::Deps::PackageVersion.new(version: "1.0.0", digest: "SHA256=bbb")

    Expect
    a != b
  end
end

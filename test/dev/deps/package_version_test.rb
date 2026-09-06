# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/declaration"
require "dev/deps/declarations"
require "dev/deps/package_version"

transform!(RSpock::AST::Transformation)
class Dev::Deps::PackageVersionTest < Minitest::Test
  test "a bare version defaults every optional fact to its empty form" do
    Given "a version with no platform, digest, artifact, or declaration facts"
    version = Dev::Deps::PackageVersion.new(version: "1.2.3")

    Expect "absence is modeled as absence — and the declared-deps claim
      defaults to the affirmative Resolved([]), never a hidden ToolOwned"
    version.version == "1.2.3"
    version.platforms == []
    version.digest.nil?
    version.artifacts == {}
    version.declarations == Dev::Deps::Declarations::Resolved.new([])
    version.metadata == {}
  end

  test "carries a ToolOwned claim when stated explicitly" do
    Given "a version of a tool-owned ecosystem"
    version = Dev::Deps::PackageVersion.new(
      version: "7.1.0",
      declarations: Dev::Deps::Declarations::ToolOwned.new,
    )

    Expect
    version.declarations == Dev::Deps::Declarations::ToolOwned.new
  end

  test "carries ecosystem-specific install facts as metadata" do
    Given "a version with facts its integration needs at install"
    version = Dev::Deps::PackageVersion.new(
      version: "3.12.0",
      metadata: { "mod_id" => "abc123", "game_version" => ">=491125" },
    )

    Expect "the facts read back and are frozen"
    version.metadata["mod_id"] == "abc123"
    version.metadata.frozen?
  end

  test "carries the full fact set when the universe provides one" do
    Given "a version with platforms, digest, per-platform artifacts, and declarations"
    artifact = Dev::Deps::Artifact.new(uri: "https://example.com/sml-linux.zip", digest: "SHA256=abc")
    edge = Dev::Deps::Declaration.new(name: "SML", integration: :ficsit, constraint: { "version" => "^3.0.0" })
    version = Dev::Deps::PackageVersion.new(
      version: "3.12.0",
      platforms: ["Windows", "LinuxServer"],
      digest: "SHA256=fff",
      artifacts: { "LinuxServer" => artifact },
      declarations: Dev::Deps::Declarations::Resolved.new([edge]),
    )

    Expect
    version.platforms == ["Windows", "LinuxServer"]
    version.digest == "SHA256=fff"
    version.artifacts["LinuxServer"] == artifact
    version.declarations == Dev::Deps::Declarations::Resolved.new([edge])
  end

  test "collection facts are frozen at construction" do
    Given "a version built from mutable collections"
    version = Dev::Deps::PackageVersion.new(
      version: "1.0.0",
      platforms: ["Windows"],
      artifacts: { "Windows" => Dev::Deps::Artifact.new(uri: "https://example.com/a.zip") },
    )

    Expect "none of them can be mutated after the fact"
    version.platforms.frozen?
    version.artifacts.frozen?
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

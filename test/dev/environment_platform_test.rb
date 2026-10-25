# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/environment_platform"
require "dev/deps/dependency"
require "dev/deps/lockfile"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::EnvironmentPlatformTest < Minitest::Test
  include SorbetHelper

  test "declared reads the build environment's platform off the Dockerfile's first FROM: #{from} -> #{expected.inspect}" do
    Given "a project whose Dockerfile opens with that FROM"
    root = project_with_dockerfile("#{from}\nRUN true\n")

    Expect "the docker platform, normalized to dev's platform key"
    Dev::EnvironmentPlatform.declared(project_root: root) == expected

    Cleanup
    FileUtils.rm_rf(root)

    Where
    from                                                 | expected
    "FROM --platform=linux/amd64 ubuntu:22.04"           | "linux-x86_64"
    "FROM --platform=linux/arm64 ubuntu:22.04"           | "linux-arm64"
    "FROM --platform=linux/arm64/v8 ubuntu:22.04"        | "linux-arm64"
    "FROM --platform=$BUILDPLATFORM ubuntu:22.04"        | nil
    "FROM ubuntu:22.04"                                  | nil
    "# comment\nFROM --platform=linux/amd64 ubuntu:22.04" | "linux-x86_64"
  end

  test "declared reads the lock's image pin first; the Dockerfile is the fallback, not a second opinion" do
    Given "a lock whose image pin says amd64 and a Dockerfile that says arm64"
    root = project_with_dockerfile("FROM --platform=linux/arm64 ubuntu:22.04\n")
    lock(root, image_pin(platform: "linux/amd64"))

    Expect "the image is the pin (dev#277); the Dockerfile path is on its way out"
    Dev::EnvironmentPlatform.declared(project_root: root) == "linux-x86_64"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "declared normalizes the pin's docker platform to dev's key: #{platform} -> #{expected}" do
    Given
    root = Pathname(Dir.mktmpdir("env-platform"))
    lock(root, image_pin(platform: platform))

    Expect
    Dev::EnvironmentPlatform.declared(project_root: root) == expected

    Cleanup
    FileUtils.rm_rf(root)

    Where
    platform         | expected
    "linux/amd64"    | "linux-x86_64"
    "linux/arm64"    | "linux-arm64"
    "linux/arm64/v8" | "linux-arm64"
  end

  test "several image pins declare a platform only when they agree: #{platforms} -> #{expected.inspect}" do
    Given "a lock with one image pin per platform listed (d3mlabs/dev#307 decides which image a command runs in)"
    root = Pathname(Dir.mktmpdir("env-platform"))
    lock(root, *platforms.each_with_index.map { |plat, i| image_pin(name: "env-#{i}", platform: plat) })

    Expect "disagreement means nothing is known, and the container stays the default"
    Dev::EnvironmentPlatform.declared(project_root: root) == expected

    Cleanup
    FileUtils.rm_rf(root)

    Where
    platforms                        | expected
    ["linux/amd64", "linux/amd64"]   | "linux-x86_64"
    ["linux/amd64", "linux/arm64"]   | nil
  end

  test "a lock without an image pin leaves the Dockerfile to declare the platform" do
    Given
    root = project_with_dockerfile("FROM --platform=linux/amd64 ubuntu:22.04\n")
    lock(root, Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build, version: "3.31", hash: "SHA256=0", metadata: {}))

    Expect
    Dev::EnvironmentPlatform.declared(project_root: root) == "linux-x86_64"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "declared is nil when there is no Dockerfile: nothing is declared" do
    Given "a project root with no Dockerfile"
    root = Pathname(Dir.mktmpdir("env-platform"))

    Expect
    Dev::EnvironmentPlatform.declared(project_root: root).nil?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "host_is_environment? is true exactly when a declared platform equals the host's: #{from} on #{host} -> #{expected}" do
    Given "a project whose Dockerfile opens with that FROM"
    root = project_with_dockerfile("#{from}\n")

    Expect "an undeclared platform never makes the host the environment (the container stays the default)"
    Dev::EnvironmentPlatform.host_is_environment?(project_root: root, host: host) == expected

    Cleanup
    FileUtils.rm_rf(root)

    Where
    from                                        | host            | expected
    "FROM --platform=linux/amd64 ubuntu:22.04"  | "linux-x86_64"  | true
    "FROM --platform=linux/amd64 ubuntu:22.04"  | "darwin-arm64"  | false
    "FROM --platform=linux/amd64 ubuntu:22.04"  | "linux-arm64"   | false
    "FROM --platform=linux/arm64 ubuntu:22.04"  | "linux-arm64"   | true
    "FROM ubuntu:22.04"                         | "linux-x86_64"  | false
  end

  private

  def lock(root, *pins)
    Dev::Deps::Lockfile.new(dir: root).lock(pins)
  end

  def image_pin(name: "snappy-linux", platform: "linux/amd64")
    Dev::Deps::Dependency.new(
      name: name, integration: :image, group: :app, version: "ue5.8-3", hash: "SHA256=#{"a" * 64}",
      metadata: {
        "from" => "ghcr.io/d3mlabs/unreal-engine-build-base", "platform" => platform, "platforms" => [platform],
        "registry" => "ghcr.io/d3mlabs", "apt" => [], "digest" => "unchecked-here",
      },
    )
  end

  def project_with_dockerfile(contents)
    root = Pathname(Dir.mktmpdir("env-platform"))
    (root / "Dockerfile").write(contents)
    root
  end
end

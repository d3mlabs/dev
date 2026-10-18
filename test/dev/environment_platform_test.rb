# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/environment_platform"
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

  def project_with_dockerfile(contents)
    root = Pathname(Dir.mktmpdir("env-platform"))
    (root / "Dockerfile").write(contents)
    root
  end
end

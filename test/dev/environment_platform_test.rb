# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/environment_platform"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::EnvironmentPlatformTest < Minitest::Test
  include SorbetHelper

  test "from_dockerfile reads the build environment's platform off the Dockerfile's first FROM: #{from} -> #{expected.inspect}" do
    Given "a project whose Dockerfile opens with that FROM"
    root = project_with_dockerfile("#{from}\nRUN true\n")

    Expect "the docker platform, normalized to dev's platform key"
    Dev::EnvironmentPlatform.from_dockerfile(root) == expected

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

  test "from_dockerfile is nil when there is no Dockerfile: nothing is declared" do
    Given "a project root with no Dockerfile"
    root = Pathname(Dir.mktmpdir("env-platform"))

    Expect
    Dev::EnvironmentPlatform.from_dockerfile(root).nil?

    Cleanup
    FileUtils.rm_rf(root)
  end

  private

  def project_with_dockerfile(contents)
    root = Pathname(Dir.mktmpdir("env-platform"))
    (root / "Dockerfile").write(contents)
    root
  end
end

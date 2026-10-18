# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/platform"

transform!(RSpock::AST::Transformation)
class Dev::PlatformTest < Minitest::Test
  include SorbetHelper

  test "key names the OS and a normalized architecture: #{ruby_platform} / #{host_cpu} -> #{expected}" do
    Expect "one spelling per OS/arch pair, whatever the toolchain calls them"
    Dev::Platform.key(ruby_platform:, host_cpu:) == expected

    Where
    ruby_platform          | host_cpu  | expected
    "x86_64-linux"         | "x86_64"  | "linux-x86_64"
    "x86_64-linux-musl"    | "x86_64"  | "linux-x86_64"
    "aarch64-linux"        | "aarch64" | "linux-arm64"
    "arm64-darwin24"       | "arm64"   | "darwin-arm64"
    "x86_64-darwin23"      | "x86_64"  | "darwin-x86_64"
    "x64-mingw-ucrt"       | "x64"     | "windows-x86_64"
  end

  test "from_docker maps a docker platform onto the same key: #{docker} -> #{expected}" do
    Expect "docker's arch spellings land on dev's"
    Dev::Platform.from_docker(docker) == expected

    Where
    docker          | expected
    "linux/amd64"   | "linux-x86_64"
    "linux/arm64"   | "linux-arm64"
    "linux/x86_64"  | "linux-x86_64"
    "darwin/arm64"  | "darwin-arm64"
  end

  test "current describes this process's platform" do
    Expect "an os-arch pair"
    Dev::Platform.current.match?(/\A(darwin|linux|windows)-(x86_64|arm64)\z/)
  end
end

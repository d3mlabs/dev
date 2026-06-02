# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/builtin_commands"
require "dev/deps/pin"
require "dev/deps/locker"
require "dev/deps/cache"
require "tmpdir"
require "yaml"

transform!(RSpock::AST::Transformation)
class Dev::Deps::BuiltinCommandsTest < Minitest::Test
  def setup
    Dev::Deps::Config.instance_variable_set(:@config, nil)
  end

  test "BUILTIN_COMMANDS includes update-deps" do
    Expect
    Dev::Deps::BuiltinCommands::BUILTIN_COMMANDS.include?("update-deps")
  end

  test "builtin? returns true for update-deps" do
    Expect
    Dev::Deps::BuiltinCommands.builtin?("update-deps")
  end

  test "builtin? returns false for arbitrary commands" do
    Expect
    !Dev::Deps::BuiltinCommands.builtin?("test")
  end

  test "install_from_lockfiles reads pins and groups by integration" do
    Given
    dir = Dir.mktmpdir("dev-builtin-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    locker = Dev::Deps::Locker.new

    # Write a deps.lock with one pin
    pins = [
      Dev::Deps::Pin.new(name: "boost", integration: :cmake, group: :app,
                          version: "1.90.0", hash: "SHA256=deadbeef",
                          metadata: { "url" => "https://example.com/boost.tar.gz" }),
    ]
    locker.write(pins, lockfile_path: File.join(dir, "deps.lock"))

    When
    grouped = Dev::Deps::BuiltinCommands.read_lockfile_pins(root: dir)

    Then
    grouped[:cmake].size == 1
    grouped[:cmake][0].name == "boost"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "read_lockfile_pins reads both deps.lock and build-deps.lock" do
    Given
    dir = Dir.mktmpdir("dev-builtin-test-")
    locker = Dev::Deps::Locker.new

    deps_pins = [
      Dev::Deps::Pin.new(name: "boost", integration: :cmake, group: :app,
                          version: "1.90.0", hash: "SHA256=aaa", metadata: {}),
    ]
    build_pins = [
      Dev::Deps::Pin.new(name: "cmake", integration: :brew, group: :build,
                          version: "3.31.4", hash: "SHA256=bbb", metadata: {}),
    ]
    locker.write(deps_pins, lockfile_path: File.join(dir, "deps.lock"))
    locker.write(build_pins, lockfile_path: File.join(dir, "build-deps.lock"))

    When
    grouped = Dev::Deps::BuiltinCommands.read_lockfile_pins(root: dir)

    Then
    grouped[:cmake].size == 1
    grouped[:brew].size == 1
    grouped[:cmake][0].name == "boost"
    grouped[:brew][0].name == "cmake"

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

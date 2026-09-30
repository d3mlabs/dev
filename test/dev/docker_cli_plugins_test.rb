# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/docker_cli_plugins"
require "fileutils"
require "json"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::DockerCliPluginsTest < Minitest::Test
  def build(dir, brew_prefix: "/opt/homebrew")
    Dev::DockerCliPlugins.new(config_path: File.join(dir, ".docker", "config.json"), brew_prefix: brew_prefix)
  end

  def read_config(dir) = JSON.parse(File.read(File.join(dir, ".docker", "config.json")))

  test "ensure! creates the config and points the CLI at brew's plugin dir when none exists" do
    Given "a home with no ~/.docker at all"
    dir = Dir.mktmpdir("dev-docker-cli-plugins-")

    When "ensuring"
    result = build(dir).ensure!

    Then "the file exists with exactly the brew plugin dir listed"
    result == :added
    read_config(dir) == { "cliPluginsExtraDirs" => ["/opt/homebrew/lib/docker/cli-plugins"] }

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure! merges into an existing config, keeping every other key and dir" do
    Given "a config carrying the user's own keys and a plugin dir of their own"
    dir = Dir.mktmpdir("dev-docker-cli-plugins-")
    FileUtils.mkdir_p(File.join(dir, ".docker"))
    File.write(File.join(dir, ".docker", "config.json"), JSON.generate(
      "auths" => { "ghcr.io" => {} },
      "currentContext" => "colima",
      "cliPluginsExtraDirs" => ["/Users/me/plugins"],
    ))

    When "ensuring"
    result = build(dir).ensure!

    Then "the brew dir is appended; nothing else moves"
    result == :added
    read_config(dir) == {
      "auths" => { "ghcr.io" => {} },
      "currentContext" => "colima",
      "cliPluginsExtraDirs" => ["/Users/me/plugins", "/opt/homebrew/lib/docker/cli-plugins"],
    }

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure! is idempotent: a config already listing the dir is left byte-identical" do
    Given "a config that already lists brew's plugin dir"
    dir = Dir.mktmpdir("dev-docker-cli-plugins-")
    path = File.join(dir, ".docker", "config.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, %({"cliPluginsExtraDirs":["/opt/homebrew/lib/docker/cli-plugins"]}\n))
    before = File.read(path)

    When "ensuring"
    result = build(dir).ensure!

    Then
    result == :already_present
    File.read(path) == before

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure! follows the brew prefix (Intel Macs live under /usr/local)" do
    Given "an Intel-style prefix"
    dir = Dir.mktmpdir("dev-docker-cli-plugins-")

    When "ensuring"
    build(dir, brew_prefix: "/usr/local").ensure!

    Then
    read_config(dir)["cliPluginsExtraDirs"] == ["/usr/local/lib/docker/cli-plugins"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure! refuses to clobber a config it cannot parse" do
    Given "a config.json that is not JSON"
    dir = Dir.mktmpdir("dev-docker-cli-plugins-")
    path = File.join(dir, ".docker", "config.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "{ not json")

    When "ensuring"
    build(dir).ensure!

    Then "a typed error names the file; its bytes are untouched"
    raises Dev::DockerCliPlugins::UnreadableConfigError
    File.read(path) == "{ not json"

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

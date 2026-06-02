# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/brew_registry"
require "dev/deps/cache"
require "tmpdir"
require "json"

transform!(RSpock::AST::Transformation)
class Dev::Deps::BrewRegistryTest < Minitest::Test
  test "resolve parses brew info JSON and returns a Pin" do
    Given
    dir = Dir.mktmpdir("dev-brew-reg-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    registry = Dev::Deps::BrewRegistry.new
    brew_json = [{
      "name" => "cmake",
      "versions" => { "stable" => "3.31.4" },
      "bottle" => {
        "stable" => {
          "files" => {
            "arm64_sonoma" => { "sha256" => "abc123def456" },
          },
        },
      },
    }].to_json

    Open3.stubs(:capture3)
         .with("brew", "info", "--json=v1", "cmake")
         .returns([brew_json, "", stub(success?: true)])

    When
    pin = registry.resolve(
      "cmake",
      { "integration" => "brew", "group" => "build" },
      cache: cache,
    )

    Then
    pin.name == "cmake"
    pin.integration == :brew
    pin.group == :build
    pin.version == "3.31.4"
    pin.hash == "SHA256=abc123def456"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "resolve includes tap in metadata when specified" do
    Given
    dir = Dir.mktmpdir("dev-brew-reg-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    registry = Dev::Deps::BrewRegistry.new
    brew_json = [{
      "name" => "powershell",
      "versions" => { "stable" => "7.4.0" },
      "bottle" => { "stable" => { "files" => { "arm64_sonoma" => { "sha256" => "ps123" } } } },
    }].to_json

    Open3.stubs(:capture3)
         .with("brew", "info", "--json=v1", "d3mlabs/d3mlabs/powershell")
         .returns([brew_json, "", stub(success?: true)])

    When
    pin = registry.resolve(
      "powershell",
      { "integration" => "brew", "group" => "build", "tap" => "d3mlabs/d3mlabs" },
      cache: cache,
    )

    Then
    pin.name == "powershell"
    pin.metadata["tap"] == "d3mlabs/d3mlabs"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "resolve handles cask entries (no hash)" do
    Given
    dir = Dir.mktmpdir("dev-brew-reg-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    registry = Dev::Deps::BrewRegistry.new

    When
    pin = registry.resolve(
      "powershell",
      { "integration" => "brew", "group" => "build", "cask" => true },
      cache: cache,
    )

    Then
    pin.name == "powershell"
    pin.version.nil?
    pin.hash.nil?
    pin.metadata["cask"] == true

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

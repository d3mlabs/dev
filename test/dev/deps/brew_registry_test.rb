# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/brew_registry"
require "dev/deps/cache"
require "tmpdir"
require "json"

transform!(RSpock::AST::Transformation)
class Dev::Deps::BrewRegistryTest < Minitest::Test
  test "fetch parses brew info JSON and returns a Dependency" do
    Given "a brew formula identifier"
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

    When "fetching the dependency"
    dep = registry.fetch(
      "name" => "cmake",
      "integration" => "brew",
      "group" => "build",
    )

    Then
    dep.name == "cmake"
    dep.integration == :brew
    dep.group == :build
    dep.version == "3.31.4"
    dep.hash == "SHA256=abc123def456"
  end

  test "fetch includes tap in metadata when specified" do
    Given "a tapped formula identifier"
    registry = Dev::Deps::BrewRegistry.new
    brew_json = [{
      "name" => "powershell",
      "versions" => { "stable" => "7.4.0" },
      "bottle" => { "stable" => { "files" => { "arm64_sonoma" => { "sha256" => "ps123" } } } },
    }].to_json

    Open3.stubs(:capture3)
         .with("brew", "info", "--json=v1", "d3mlabs/d3mlabs/powershell")
         .returns([brew_json, "", stub(success?: true)])

    When "fetching with a tap"
    dep = registry.fetch(
      "name" => "powershell",
      "integration" => "brew",
      "group" => "build",
      "tap" => "d3mlabs/d3mlabs",
    )

    Then
    dep.name == "powershell"
    dep.metadata["tap"] == "d3mlabs/d3mlabs"
  end

  test "fetch handles cask entries (no hash)" do
    Given "a cask identifier"
    registry = Dev::Deps::BrewRegistry.new

    When "fetching a cask"
    dep = registry.fetch(
      "name" => "powershell",
      "integration" => "brew",
      "group" => "build",
      "cask" => true,
    )

    Then
    dep.name == "powershell"
    dep.version.nil?
    dep.hash.nil?
    dep.metadata["cask"] == true
  end
end

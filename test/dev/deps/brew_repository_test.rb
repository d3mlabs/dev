# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/brew_repository"
require "dev/deps/cache"
require "tmpdir"
require "json"

transform!(RSpock::AST::Transformation)
class Dev::Deps::BrewRepositoryTest < Minitest::Test
  test "fetch parses brew info JSON and returns a Dependency" do
    Given "a brew formula identifier"
    repository = Dev::Deps::BrewRepository.new
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
    dep = repository.fetch(
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

  test "fetch treats declared version as a formula suffix and records the resolved version" do
    Given "a formula declared with a version suffix"
    repository = Dev::Deps::BrewRepository.new
    brew_json = [{
      "name" => "llvm@18",
      "versions" => { "stable" => "18.1.8" },
      "bottle" => { "stable" => { "files" => { "arm64_sonoma" => { "sha256" => "llvm18" } } } },
    }].to_json

    Open3.stubs(:capture3)
         .with("brew", "info", "--json=v1", "llvm@18")
         .returns([brew_json, "", stub(success?: true)])

    When "fetching with version: 18"
    dep = repository.fetch(
      "name" => "llvm",
      "integration" => "brew",
      "group" => "build",
      "version" => "18",
    )

    Then "the resolved version is recorded and the suffix is kept for install"
    dep.name == "llvm"
    dep.version == "18.1.8"
    dep.hash == "SHA256=llvm18"
    dep.metadata["version_suffix"] == "18"
  end

  test "fetch includes tap in metadata when specified" do
    Given "a tapped formula identifier"
    repository = Dev::Deps::BrewRepository.new
    brew_json = [{
      "name" => "powershell",
      "versions" => { "stable" => "7.4.0" },
      "bottle" => { "stable" => { "files" => { "arm64_sonoma" => { "sha256" => "ps123" } } } },
    }].to_json

    Open3.stubs(:capture3)
         .with("brew", "info", "--json=v1", "d3mlabs/d3mlabs/powershell")
         .returns([brew_json, "", stub(success?: true)])

    When "fetching with a tap"
    dep = repository.fetch(
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
    repository = Dev::Deps::BrewRepository.new

    When "fetching a cask"
    dep = repository.fetch(
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

  test "fetch raises BrewInfoError when brew info fails" do
    Given "a formula that brew info cannot resolve"
    repository = Dev::Deps::BrewRepository.new
    failed_status = stub(success?: false)
    Open3.stubs(:capture3)
         .with("brew", "info", "--json=v1", "nonexistent")
         .returns(["", "Error: No available formula", failed_status])

    When "fetching the dependency"
    repository.fetch(
      "name" => "nonexistent",
      "integration" => "brew",
      "group" => "build",
    )

    Then
    raises Dev::Deps::BrewRepository::BrewInfoError
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/brew_repository"
require "dev/deps/cache"
require "tmpdir"
require "json"

transform!(RSpock::AST::Transformation)
class Dev::Deps::BrewRepositoryTest < Minitest::Test
  test "find reports the formula's current stable version as a singleton universe" do
    Given "a formula on the moving brew registry"
    repository = Dev::Deps::BrewRepository.new
    brew_json = [{
      "name" => "cmake",
      "versions" => { "stable" => "3.31.4" },
      "bottle" => {
        "stable" => { "files" => { "arm64_sonoma" => { "sha256" => "abc123def456" } } },
      },
    }].to_json
    Open3.stubs(:capture3)
         .with("brew", "info", "--json=v1", "cmake")
         .returns([brew_json, "", stub(success?: true)])

    When "finding the package"
    package = repository.find(Dev::Deps::PackageId.new(integration: :brew, name: "cmake"))

    Then "one version, carrying the bottle digest"
    package.versions.map(&:version) == ["3.31.4"]
    package.version("3.31.4").digest == "SHA256=abc123def456"
    package.version("3.31.4").metadata == {}
  end

  test "find locates the suffixed formula via the version filter" do
    Given "a formula declared with a version suffix and a tap"
    repository = Dev::Deps::BrewRepository.new
    brew_json = [{
      "name" => "llvm@18",
      "versions" => { "stable" => "18.1.8" },
      "bottle" => { "stable" => { "files" => { "arm64_sonoma" => { "sha256" => "llvm18" } } } },
    }].to_json
    Open3.stubs(:capture3)
         .with("brew", "info", "--json=v1", "someorg/sometap/llvm@18")
         .returns([brew_json, "", stub(success?: true)])

    When "finding with the suffix and tap as locator"
    package = repository.find(
      Dev::Deps::PackageId.new(integration: :brew, name: "llvm"),
      filter: { "version" => "18", "tap" => "someorg/sometap" },
    )

    Then "the suffixed formula's stable version, with locator facts recorded"
    package.versions.map(&:version) == ["18.1.8"]
    package.version("18.1.8").metadata == { "tap" => "someorg/sometap", "version_suffix" => "18" }
  end

  test "find reports a cask as one unversioned, undigested entry" do
    Given "a cask declaration"
    repository = Dev::Deps::BrewRepository.new

    When "finding with the cask flag"
    package = repository.find(
      Dev::Deps::PackageId.new(integration: :brew, name: "firefox"),
      filter: { "cask" => true },
    )

    Then "brew exposes no cask version here — an empty version stand-in"
    package.versions.map(&:version) == [Dev::Deps::BrewRepository::UNVERSIONED]
    package.versions.first.digest.nil?
    package.versions.first.metadata == { "cask" => true }
  end

  test "find registers the declared tap and retries when brew info fails untapped" do
    Given "a tapped formula on a machine that has never tapped it"
    repository = Dev::Deps::BrewRepository.new
    brew_json = [{
      "name" => "xcodes",
      "versions" => { "stable" => "1.6.2" },
      "bottle" => { "stable" => { "files" => { "arm64_sonoma" => { "sha256" => "xc123" } } } },
    }].to_json

    Open3.stubs(:capture3)
         .with("brew", "info", "--json=v1", "xcodesorg/made/xcodes")
         .returns(["", "Error: this command requires the tap", stub(success?: false)])
         .then.returns([brew_json, "", stub(success?: true)])
    Open3.stubs(:capture3)
         .with("brew", "tap", "xcodesorg/made")
         .returns(["", "", stub(success?: true)])

    When "finding with the tap as locator"
    package = repository.find(
      Dev::Deps::PackageId.new(integration: :brew, name: "xcodes"),
      filter: { "tap" => "xcodesorg/made" },
    )

    Then "the tap was registered and resolution succeeded on retry"
    package.versions.map(&:version) == ["1.6.2"]
    package.version("1.6.2").metadata["tap"] == "xcodesorg/made"
  end

  test "find raises BrewInfoError when brew info fails" do
    Given "a formula that brew info cannot resolve"
    repository = Dev::Deps::BrewRepository.new
    failed_status = stub(success?: false)
    Open3.stubs(:capture3)
         .with("brew", "info", "--json=v1", "nonexistent")
         .returns(["", "Error: No available formula", failed_status])

    When "finding the package"
    repository.find(Dev::Deps::PackageId.new(integration: :brew, name: "nonexistent"))

    Then
    raises Dev::Deps::BrewRepository::BrewInfoError
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/brew_repository"
require "json"

transform!(RSpock::AST::Transformation)
class Dev::Deps::BrewRepositoryTest < Minitest::Test
  def formula_json(name, stable:, sha: nil, versioned: [])
    json = { "name" => name, "versions" => { "stable" => stable }, "versioned_formulae" => versioned }
    if sha
      json["bottle"] = { "stable" => { "files" => { "arm64_sonoma" => { "sha256" => sha } } } }
    end
    json
  end

  def stub_brew_info(specs, infos)
    Open3.stubs(:capture3)
         .with("brew", "info", "--json=v1", *specs)
         .returns([JSON.generate(infos), "", stub(success?: true)])
  end

  test "find reports a family-less formula as a singleton universe" do
    Given "a formula with no versioned siblings"
    repository = Dev::Deps::BrewRepository.new
    stub_brew_info(["cmake"], [formula_json("cmake", stable: "3.31.4", sha: "abc123def456")])

    When "finding the package"
    package = repository.find(Dev::Deps::PackageId.new(integration: :brew, name: "cmake"))

    Then "one version, carrying the bottle digest"
    package.versions.map(&:version) == ["3.31.4"]
    package.version("3.31.4").digest == "SHA256=abc123def456"
    package.version("3.31.4").metadata == {}
  end

  test "find enumerates the spec family — siblings' suffixes ride as facts, bare spec last" do
    Given "llvm with two versioned siblings"
    repository = Dev::Deps::BrewRepository.new
    stub_brew_info(["llvm"],
      [formula_json("llvm", stable: "21.1.0", sha: "llvm21", versioned: ["llvm@19", "llvm@18"])])
    stub_brew_info(["llvm@19", "llvm@18"], [
      formula_json("llvm@19", stable: "19.1.7", sha: "llvm19"),
      formula_json("llvm@18", stable: "18.1.8", sha: "llvm18"),
    ])

    When "finding"
    package = repository.find(Dev::Deps::PackageId.new(integration: :brew, name: "llvm"))

    Then "one version per spec; the bare spec sits last as the unconstrained pick"
    package.versions.map(&:version) == ["19.1.7", "18.1.8", "21.1.0"]
    package.version("18.1.8").metadata == { "version_suffix" => "18" }
    package.version("18.1.8").digest == "SHA256=llvm18"
    package.version("21.1.0").metadata == {}
  end

  test "find skips head-only siblings without a stable version" do
    Given "a family whose sibling reports no stable version"
    repository = Dev::Deps::BrewRepository.new
    stub_brew_info(["tool"], [formula_json("tool", stable: "2.0.0", versioned: ["tool@head"])])
    stub_brew_info(["tool@head"], [formula_json("tool@head", stable: nil)])

    When "finding"
    package = repository.find(Dev::Deps::PackageId.new(integration: :brew, name: "tool"))

    Then "no stable version means not a version"
    package.versions.map(&:version) == ["2.0.0"]
  end

  test "find ignores the probe — the spec family is enumerable" do
    Given "a formula"
    repository = Dev::Deps::BrewRepository.new
    stub_brew_info(["cmake"], [formula_json("cmake", stable: "3.31.4")])

    When "finding with a leftover probe"
    package = repository.find(Dev::Deps::PackageId.new(integration: :brew, name: "cmake"), probe: "18")

    Then
    package.versions.map(&:version) == ["3.31.4"]
  end

  test "find qualifies family queries with the tap and records it as a fact" do
    Given "a tapped formula"
    repository = Dev::Deps::BrewRepository.new
    stub_brew_info(["someorg/sometap/mytool"],
      [formula_json("mytool", stable: "1.2.0", sha: "mt12")])

    When "finding with the tap on the id"
    package = repository.find(
      Dev::Deps::PackageId.new(integration: :brew, name: "mytool", source: "someorg/sometap"),
    )

    Then
    package.versions.map(&:version) == ["1.2.0"]
    package.version("1.2.0").metadata == { "tap" => "someorg/sometap" }
  end

  test "find registers the declared tap and retries when brew info fails untapped" do
    Given "a tapped formula on a machine that has never tapped it"
    repository = Dev::Deps::BrewRepository.new
    brew_json = JSON.generate([formula_json("xcodes", stable: "1.6.2", sha: "xc123")])

    Open3.stubs(:capture3)
         .with("brew", "info", "--json=v1", "xcodesorg/made/xcodes")
         .returns(["", "Error: this command requires the tap", stub(success?: false)])
         .then.returns([brew_json, "", stub(success?: true)])
    Open3.stubs(:capture3)
         .with("brew", "tap", "xcodesorg/made")
         .returns(["", "", stub(success?: true)])

    When "finding with the tap on the id"
    package = repository.find(
      Dev::Deps::PackageId.new(integration: :brew, name: "xcodes", source: "xcodesorg/made"),
    )

    Then "the tap was registered and resolution succeeded on retry"
    package.versions.map(&:version) == ["1.6.2"]
    package.version("1.6.2").metadata["tap"] == "xcodesorg/made"
  end

  test "find raises BrewInfoError when brew info fails" do
    Given "a formula that brew info cannot resolve"
    repository = Dev::Deps::BrewRepository.new
    Open3.stubs(:capture3)
         .with("brew", "info", "--json=v1", "nonexistent")
         .returns(["", "Error: No available formula", stub(success?: false)])

    When "finding the package"
    repository.find(Dev::Deps::PackageId.new(integration: :brew, name: "nonexistent"))

    Then
    raises Dev::Deps::BrewRepository::BrewInfoError
  end
end

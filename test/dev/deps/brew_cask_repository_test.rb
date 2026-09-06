# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/brew_cask_repository"

transform!(RSpock::AST::Transformation)
class Dev::Deps::BrewCaskRepositoryTest < Minitest::Test
  test "find reports a cask as one unversioned, undigested, tool-owned entry" do
    Given "a cask id"
    repository = Dev::Deps::BrewCaskRepository.new

    When "finding"
    package = repository.find(Dev::Deps::PackageId.new(integration: :cask, name: "firefox"))

    Then "brew exposes no cask version — an empty version stand-in, brew owns the closure"
    package.versions.map(&:version) == [Dev::Deps::BrewCaskRepository::UNVERSIONED]
    package.versions.first.digest.nil?
    package.versions.first.metadata == { "cask" => true }
    package.versions.first.declarations == Dev::Deps::Declarations::ToolOwned.new
  end

  test "find records a declared suffix as the version_suffix fact" do
    Given "a cask pinned to a versioned spec"
    repository = Dev::Deps::BrewCaskRepository.new

    When "finding with a probe"
    package = repository.find(
      Dev::Deps::PackageId.new(integration: :cask, name: "temurin"),
      probe: "21",
    )

    Then
    package.versions.first.metadata == { "cask" => true, "version_suffix" => "21" }
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/brew_cask_repository"
require "dev/deps/cask_scheme"
require "dev/deps/requirement"

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

  test "a requirement on a cask is refused — the cask name is the coordinate" do
    Given "a cask's singleton universe (versioned casks are distinct names, e.g. temurin@21)"
    repository = Dev::Deps::BrewCaskRepository.new
    package = repository.find(Dev::Deps::PackageId.new(integration: :cask, name: "temurin"))
    scheme = Dev::Deps::CaskScheme.new

    Expect "the channel takes Any alone; its one entry satisfies nothing else"
    !scheme.supports?(Dev::Deps::Requirement.parse("~> 21.0"))
    scheme.satisfies?(package.versions.first, Dev::Deps::Requirement::Any.new)
    !scheme.satisfies?(package.versions.first, Dev::Deps::Requirement.parse("~> 21.0"))
  end
end

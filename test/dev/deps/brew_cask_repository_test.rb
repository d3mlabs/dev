# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/brew_cask_repository"
require "dev/deps/brew_scheme"

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

  test "a version constraint on a cask is unsatisfiable — the cask name is the coordinate" do
    Given "a cask's singleton universe (versioned casks are distinct names, e.g. temurin@21)"
    repository = Dev::Deps::BrewCaskRepository.new
    package = repository.find(Dev::Deps::PackageId.new(integration: :cask, name: "temurin"))

    When "evaluating a suffix constraint against it"
    satisfied = Dev::Deps::BrewScheme.new.satisfies?(package.versions.first, { "version" => "21" })

    Then "no suffix fact exists to match — the resolve fails loudly, not silently"
    satisfied == false
  end
end

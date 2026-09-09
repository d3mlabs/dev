# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/xcode_repository"

transform!(RSpock::AST::Transformation)
class Dev::Deps::XcodeRepositoryTest < Minitest::Test
  test "at lifts the declared version as the identity — no registry exists to consult" do
    Given "an xcode revision"
    repo = Dev::Deps::XcodeRepository.new

    When "lifting"
    version = repo.at(Dev::Deps::PackageId.new(integration: :xcode, name: "xcode"), "26.1.1")

    Then "the version is the address; Apple ships the whole toolchain"
    version.version == "26.1.1"
    version.digest.nil?
    version.declarations == Dev::Deps::Declarations::Resolved.new([])
  end

  test "find refuses — there is no enumerable Xcode universe" do
    Given "a constraint-shaped ask"
    repo = Dev::Deps::XcodeRepository.new

    When "finding"
    repo.find(Dev::Deps::PackageId.new(integration: :xcode, name: "xcode"))

    Then
    raises Dev::Deps::XcodeRepository::NoEnumerableUniverseError
  end
end

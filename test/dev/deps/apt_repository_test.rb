# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/apt_repository"

transform!(RSpock::AST::Transformation)
class Dev::Deps::AptRepositoryTest < Minitest::Test
  test "at lifts the suite address as the identity — apt publishes no cross-host version to pin" do
    Given "an apt declaration's revision"
    repo = Dev::Deps::AptRepository.new

    When "lifting"
    version = repo.at(Dev::Deps::PackageId.new(integration: :apt, name: "winehq-stable"), "suite")

    Then "the version is the address; the host's suite decides the build that installs"
    version.version == "suite"
    version.digest.nil?
    version.declarations == Dev::Deps::Declarations::Resolved.new([])
  end

  test "find refuses — apt versions are per distro release, not one universe" do
    Given "a constraint-shaped ask"
    repo = Dev::Deps::AptRepository.new

    When "finding"
    repo.find(Dev::Deps::PackageId.new(integration: :apt, name: "xvfb"))

    Then
    raises Dev::Deps::AptRepository::NoEnumerableUniverseError
  end
end

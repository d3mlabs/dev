# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/wwise_repository"

transform!(RSpock::AST::Transformation)
class Dev::Deps::WwiseRepositoryTest < Minitest::Test
  test "at lifts the declared SDK version as the identity — Audiokinetic publishes no registry to consult" do
    Given "a wwise revision"
    repo = Dev::Deps::WwiseRepository.new

    When "lifting"
    version = repo.at(Dev::Deps::PackageId.new(integration: :wwise, name: "Wwise"), "2023.1.14.8770")

    Then "the version is the address; the SDK package is self-contained"
    version.version == "2023.1.14.8770"
    version.digest.nil?
    version.declarations == Dev::Deps::Declarations::Resolved.new([])
  end

  test "find refuses — enumerating Wwise versions needs an Audiokinetic login, and resolution never has one" do
    Given "a constraint-shaped ask"
    repo = Dev::Deps::WwiseRepository.new

    When "finding"
    repo.find(Dev::Deps::PackageId.new(integration: :wwise, name: "Wwise"))

    Then
    raises Dev::Deps::WwiseRepository::NoEnumerableUniverseError
  end
end

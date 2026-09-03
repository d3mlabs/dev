# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/xcode_repository"

transform!(RSpock::AST::Transformation)
class Dev::Deps::XcodeRepositoryTest < Minitest::Test
  test "find reports the declared version as a singleton universe" do
    Given "an xcode declaration"
    repo = Dev::Deps::XcodeRepository.new

    When "finding with the exact version as locator"
    package = repo.find(
      Dev::Deps::PackageId.new(integration: :xcode, name: "xcode"),
      filter: { "version" => "26.1.1" },
    )

    Then "resolution is the identity — no registry exists to consult"
    package.versions.map(&:version) == ["26.1.1"]
    package.version("26.1.1").digest.nil?
    package.version("26.1.1").metadata == {}
  end

  test "find without an exact version raises MissingVersionError" do
    Given "a declaration missing the version pin"
    repo = Dev::Deps::XcodeRepository.new

    When "finding"
    repo.find(Dev::Deps::PackageId.new(integration: :xcode, name: "xcode"))

    Then
    raises Dev::Deps::XcodeRepository::MissingVersionError
  end
end

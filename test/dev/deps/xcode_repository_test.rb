# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/xcode_repository"

transform!(RSpock::AST::Transformation)
class Dev::Deps::XcodeRepositoryTest < Minitest::Test
  test "fetch resolves the declared exact version as the locked version" do
    Given "an xcode declaration id"
    repo = Dev::Deps::XcodeRepository.new
    id = { "name" => "xcode", "integration" => "xcode", "group" => "build", "version" => "26.1.1" }

    When "fetching"
    dep = repo.fetch(id)

    Then "resolution is the identity — no registry exists to consult"
    dep.name == "xcode"
    dep.integration == :xcode
    dep.group == :build
    dep.version == "26.1.1"
    dep.hash.nil?
  end

  test "fetch without an exact version raises" do
    Given "a declaration missing the version pin"
    repo = Dev::Deps::XcodeRepository.new
    id = { "name" => "xcode", "integration" => "xcode", "group" => "build" }

    When "fetching"
    error = assert_raises(Dev::Deps::XcodeRepository::MissingVersionError) do
      repo.fetch(id)
    end

    Then
    error.message.include?("exact version")
  end
end

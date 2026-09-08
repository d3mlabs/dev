# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/repository"
require "dev/deps/package_id"

transform!(RSpock::AST::Transformation)
class Dev::Deps::RepositoryTest < Minitest::Test
  test "base class find raises NotImplementedError" do
    Given "a base Repository instance"
    repo = Dev::Deps::Repository.new

    When "finding a package"
    repo.find(Dev::Deps::PackageId.new(integration: :cmake, name: "boost"))

    Then
    raises NotImplementedError
  end

  test "base class at refuses — no continuous space unless a repository declares one" do
    Given "a base Repository instance"
    repo = Dev::Deps::Repository.new

    When "addressing a revision"
    act = lambda { repo.at(Dev::Deps::PackageId.new(integration: :brew, name: "llvm"), "a" * 40) }

    Then "overriding at is the declaration of an addressable space; the base has none"
    error = assert_raises(Dev::Deps::Repository::NoAddressableSpaceError) { act.call }
    error.message.include?("llvm")
  end
end

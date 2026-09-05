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
end

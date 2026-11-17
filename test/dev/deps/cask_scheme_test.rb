# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/package_version"
require "dev/deps/requirement"
require "dev/deps/cask_scheme"

transform!(RSpock::AST::Transformation)
class Dev::Deps::CaskSchemeTest < Minitest::Test
  Requirement = Dev::Deps::Requirement

  def scheme
    Dev::Deps::CaskScheme.new
  end

  def pv
    Dev::Deps::PackageVersion.new(version: "latest")
  end

  test "a cask takes Any alone" do
    Expect
    scheme.supports?(Requirement::Any.new)
    !scheme.supports?(Requirement.parse("= 21"))
    !scheme.supports?(Requirement.parse("~> 21.0"))
    !scheme.supports?(Requirement.parse(">= 21"))
  end

  test "supported names the way a versioned cask is spelled" do
    Expect
    scheme.supported.include?("Homebrew publishes none for casks")
    scheme.supported.include?('brew "temurin@21", cask: true')
  end

  test "the one unversioned entry satisfies Any and nothing else" do
    Expect
    scheme.satisfies?(pv, Requirement::Any.new)
    !scheme.satisfies?(pv, Requirement::Exact.new(version: "latest"))
  end

  test "sort leaves the singleton as reported" do
    Given
    versions = [pv]

    Expect
    scheme.sort(versions) == versions
  end
end

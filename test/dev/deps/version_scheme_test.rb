# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/package_version"
require "dev/deps/requirement"
require "dev/deps/version_scheme"

transform!(RSpock::AST::Transformation)
class Dev::Deps::VersionSchemeTest < Minitest::Test
  Requirement = Dev::Deps::Requirement

  def version
    Dev::Deps::PackageVersion.new(version: "1.0.0")
  end

  test "base class satisfies? raises NotImplementedError" do
    When "asking the abstract scheme to evaluate a requirement"
    Dev::Deps::VersionScheme.new.satisfies?(version, Requirement.parse(">= 1.0"))

    Then
    raises NotImplementedError
  end

  test "base class sort raises NotImplementedError" do
    When "asking the abstract scheme to order versions"
    Dev::Deps::VersionScheme.new.sort([version])

    Then
    raises NotImplementedError
  end

  test "by default a scheme supports every form and refuses nothing" do
    Given
    scheme = Dev::Deps::VersionScheme.new

    Expect
    scheme.supports?(Requirement::Any.new)
    scheme.supports?(Requirement.parse("~> 1"))
    scheme.supported == "any requirement"
    scheme.refusal(name: "x", requirement: Requirement.parse("~> 1"), versions: [version]).nil?
    scheme.unsatisfied(name: "x", requirement: Requirement.parse("~> 1"), versions: [version]).nil?
  end
end

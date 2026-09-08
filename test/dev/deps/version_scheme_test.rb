# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/package_version"
require "dev/deps/version_scheme"

transform!(RSpock::AST::Transformation)
class Dev::Deps::VersionSchemeTest < Minitest::Test
  test "base class satisfies? raises NotImplementedError" do
    When "asking the abstract scheme to evaluate a constraint"
    version = Dev::Deps::PackageVersion.new(version: "1.0.0")
    Dev::Deps::VersionScheme.new.satisfies?(version, { "version" => ">= 1.0" })

    Then
    raises NotImplementedError
  end

  test "base class sort raises NotImplementedError" do
    When "asking the abstract scheme to order versions"
    Dev::Deps::VersionScheme.new.sort(["1.0.0", "2.0.0"])

    Then
    raises NotImplementedError
  end
end

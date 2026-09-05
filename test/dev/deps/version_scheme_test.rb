# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/version_scheme"

transform!(RSpock::AST::Transformation)
class Dev::Deps::VersionSchemeTest < Minitest::Test
  test "base class satisfies? raises NotImplementedError" do
    When "asking the abstract scheme to evaluate a constraint"
    Dev::Deps::VersionScheme.new.satisfies?("1.0.0", { "version" => ">= 1.0" })

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

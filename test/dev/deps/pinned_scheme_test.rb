# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/pinned_scheme"

transform!(RSpock::AST::Transformation)
class Dev::Deps::PinnedSchemeTest < Minitest::Test
  def scheme
    Dev::Deps::PinnedScheme.new
  end

  test "every reported version satisfies every constraint" do
    Expect "the backing service already narrowed the universe to the declared identity"
    scheme.satisfies?("a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0", { "tag" => "v1.2.3" })
    scheme.satisfies?("5.6.1-css-83", { "tag" => "5.6.1-css-83" })
    scheme.satisfies?("20240101", { "buildid" => "20240101" })
    scheme.satisfies?("26.1.1", {})
  end

  test "sort preserves the repository-reported order" do
    Given "versions in the order the repository reported them"
    versions = ["current", "older"]

    When "sorting"
    sorted = scheme.sort(versions)

    Then "the order is untouched — a pinned universe has no version order to impose"
    sorted == ["current", "older"]
  end
end

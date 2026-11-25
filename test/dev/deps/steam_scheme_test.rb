# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/package_version"
require "dev/deps/requirement"
require "dev/deps/steam_scheme"

transform!(RSpock::AST::Transformation)
class Dev::Deps::SteamSchemeTest < Minitest::Test
  Requirement = Dev::Deps::Requirement

  def scheme
    Dev::Deps::SteamScheme.new
  end

  def pv(buildid, branch: "public")
    Dev::Deps::PackageVersion.new(version: buildid, metadata: { "branch" => branch })
  end

  test "buildid #{buildid.inspect} against #{expression.inspect} is #{expected}" do
    When "evaluating the branch tip against the ask"
    result = scheme.satisfies?(pv(buildid), Requirement.parse(expression))

    Then
    result == expected

    Where
    buildid    | expression    | expected
    "15321746" | nil           | true
    "15321746" | "= 15321746"  | true
    "15321746" | "15321746"    | true
    "15321746" | "= 99999"     | false
  end

  test "steam takes Any and an exact buildid, nothing else, until a build history exists" do
    Expect
    scheme.supports?(Requirement::Any.new)
    scheme.supports?(Requirement.parse("= 15321746"))
    !scheme.supports?(Requirement.parse(">= 15321746"))
    !scheme.supports?(Requirement.parse("^15321746"))
    scheme.supported.include?("exact buildid")
  end

  test "a pinned buildid that is no longer the branch tip is explained with the tip and both ways out (dev#451)" do
    Given "the branch's tip has moved past the pin"
    universe = [pv("26000000", branch: "public")]

    When
    message = scheme.unsatisfied(name: "SatisfactoryServer", requirement: Requirement.parse("= 25782485"), versions: universe)

    Then
    message == "SatisfactoryServer: buildid 25782485 is no longer the tip of `public` (now 26000000); " \
      "Steam serves only branch tips — bump `buildid:` to it, or drop `buildid:` to follow the branch"
  end

  test "an empty universe or a non-exact ask has no Steam-specific explanation" do
    Expect
    scheme.unsatisfied(name: "x", requirement: Requirement.parse("= 1"), versions: []).nil?
    scheme.unsatisfied(name: "x", requirement: Requirement::Any.new, versions: [pv("1")]).nil?
  end

  test "sort orders buildids numerically ascending" do
    When "sorting"
    sorted = scheme.sort([pv("15400000"), pv("999"), pv("15321746")]).map(&:version)

    Then "buildids are monotonically increasing integers, not lexical strings"
    sorted == ["999", "15321746", "15400000"]
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/package_version"
require "dev/deps/steam_scheme"

transform!(RSpock::AST::Transformation)
class Dev::Deps::SteamSchemeTest < Minitest::Test
  def scheme
    Dev::Deps::SteamScheme.new
  end

  def pv(buildid, branch:)
    Dev::Deps::PackageVersion.new(version: buildid, metadata: { "branch" => branch })
  end

  test "branch #{branch.inspect} buildid #{buildid.inspect} against #{constraint} is #{expected}" do
    When "evaluating branch selection plus optional buildid assertion"
    result = scheme.satisfies?(pv(buildid, branch: branch), constraint)

    Then
    result == expected

    Where
    branch         | buildid    | constraint                                        | expected
    "public"       | "15321746" | {}                                                | true
    "public"       | "15321746" | { "branch" => "public" }                          | true
    "experimental" | "15400000" | { "branch" => "public" }                          | false
    "experimental" | "15400000" | { "branch" => "experimental" }                    | true
    "public"       | "15321746" | { "buildid" => "15321746" }                       | true
    "public"       | "15321746" | { "buildid" => "99999" }                          | false
    "experimental" | "15400000" | { "branch" => "experimental", "buildid" => "15400000" } | true
  end

  test "a pinned buildid that is no longer the branch tip is explained with the tip and both ways out (dev#451)" do
    Given "the universe's public tip has moved past the pin"
    universe = [pv("26000000", branch: "public"), pv("26100000", branch: "experimental")]

    When
    message = scheme.unsatisfied(name: "SatisfactoryServer", constraint: { "buildid" => 25782485, "branch" => "public" }, versions: universe)

    Then
    message == "SatisfactoryServer: buildid 25782485 is no longer the tip of `public` (now 26000000); " \
      "Steam serves only branch tips — bump `buildid:` to it, or drop `buildid:` to follow the branch"
  end

  test "a branch the app does not publish is explained with the branches it does" do
    Given
    universe = [pv("26000000", branch: "public"), pv("26100000", branch: "experimental")]

    When
    message = scheme.unsatisfied(name: "SatisfactoryServer", constraint: { "branch" => "beta" }, versions: universe)

    Then
    message == "SatisfactoryServer: Steam publishes no `beta` branch (branches: experimental 26100000, public 26000000)"
  end

  test "sort orders buildids numerically ascending" do
    When "sorting"
    sorted = scheme.sort(["15400000", "999", "15321746"])

    Then "buildids are monotonically increasing integers, not lexical strings"
    sorted == ["999", "15321746", "15400000"]
  end
end

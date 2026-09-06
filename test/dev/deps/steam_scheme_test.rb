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

  test "sort orders buildids numerically ascending" do
    When "sorting"
    sorted = scheme.sort(["15400000", "999", "15321746"])

    Then "buildids are monotonically increasing integers, not lexical strings"
    sorted == ["999", "15321746", "15400000"]
  end

  test "pin is nil — branch tips are enumerable, no probe needed" do
    When "pinning a fully constrained declaration"
    result = scheme.pin({ "branch" => "public", "buildid" => "15321746" })

    Then
    result.nil?
  end
end

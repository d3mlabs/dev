# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/clone"

transform!(RSpock::AST::Transformation)
class Dev::Clone::RepoSpecTest < Minitest::Test
  test "parses '#{arg}' as #{expected_org}/#{expected_name}" do
    When "we parse the clone target"
    spec = Dev::Clone::RepoSpec.parse(arg)

    Then "org and name land as expected"
    spec.org == expected_org
    spec.name == expected_name

    Where
    arg             | expected_org | expected_name
    "dev"           | "d3mlabs"    | "dev"
    "acme/widget"   | "acme"       | "widget"
    "My.Repo-2"     | "d3mlabs"    | "My.Repo-2"
    "JPDuchesne/x"  | "JPDuchesne" | "x"
  end

  test "renders the gh clone target and the canonical relative path" do
    Given "a parsed spec"
    spec = Dev::Clone::RepoSpec.parse("acme/widget")

    Expect "the gh target and the host/org/repo layout"
    spec.full_name == "acme/widget"
    spec.relative_path == Pathname("github.com/acme/widget")
  end

  test "rejects '#{arg}' (#{reason})" do
    When "we parse the malformed target"
    Dev::Clone::RepoSpec.parse(arg)

    Then
    raises Dev::Clone::RepoSpec::MalformedRepoError

    Where
    arg       | reason
    ""        | "empty"
    "/"       | "only a separator"
    "a/b/c"   | "too many segments"
    "a/"      | "trailing separator"
    "/b"      | "leading separator"
    "a b"     | "whitespace in a segment"
    "org/a b" | "whitespace in the repo segment"
  end
end

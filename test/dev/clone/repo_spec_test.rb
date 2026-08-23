# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/clone"

transform!(RSpock::AST::Transformation)
class Dev::Clone::RepoSpecTest < Minitest::Test
  test "parses '#{arg}' as #{expected_org}/#{expected_name} with a default org configured" do
    When "we parse the clone target"
    spec = Dev::Clone::RepoSpec.parse(arg, default_org: "d3mlabs")

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

  test "an explicit <org>/<repo> needs no default org" do
    When "we parse a fully-qualified target with no default org"
    spec = Dev::Clone::RepoSpec.parse("acme/widget")

    Then
    spec.org == "acme"
    spec.name == "widget"
  end

  test "a bare <repo> with no default org raises MissingDefaultOrgError naming the settings key" do
    When "we parse a bare target with no default org"
    error = assert_raises(Dev::Clone::RepoSpec::MissingDefaultOrgError) do
      Dev::Clone::RepoSpec.parse("dev")
    end

    Then "the remediation names both the key and the ENV override"
    assert_includes error.message, "default_org"
    assert_includes error.message, "DEV_DEFAULT_ORG"
  end

  test "renders the gh clone target and the canonical relative path" do
    Given "a parsed spec"
    spec = Dev::Clone::RepoSpec.parse("acme/widget", default_org: "d3mlabs")

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

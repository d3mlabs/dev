# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cd"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::Cd::MatcherTest < Minitest::Test
  test "a unique leaf name resolves to its repo" do
    Given "a matcher over two distinctly named repos"
    matcher = build_matcher(["github.com/d3mlabs/dev", "github.com/d3mlabs/ai-flow"])

    When "we resolve by leaf name"
    repo = matcher.resolve("dev")

    Then "the matching repo is returned"
    repo.segments == ["github.com", "d3mlabs", "dev"]
  end

  test "matching is case-insensitive" do
    Given "a matcher over a mixed-case repo name"
    matcher = build_matcher(["github.com/d3mlabs/MyRepo"])

    Expect "a lowercase query matches"
    matcher.resolve("myrepo").name == "MyRepo"
  end

  test "an ambiguous leaf raises AmbiguousRepoError with org/repo candidates" do
    Given "two repos with the same leaf name under different orgs"
    matcher = build_matcher(["github.com/d3mlabs/dev", "github.com/someone/dev"])

    When "we resolve the shared leaf"
    matcher.resolve("dev")

    Then
    raises Dev::Cd::Matcher::AmbiguousRepoError
  end

  test "ambiguous candidates render at the shortest unique depth (org/repo)" do
    Given "two repos with the same leaf name"
    matcher = build_matcher(["github.com/d3mlabs/dev", "github.com/someone/dev"])

    When "we resolve the shared leaf"
    error = assert_raises(Dev::Cd::Matcher::AmbiguousRepoError) { matcher.resolve("dev") }

    Then "candidates carry the disambiguating org"
    error.candidates == ["d3mlabs/dev", "someone/dev"]
  end

  test "org/repo disambiguates a shared leaf" do
    Given "two repos with the same leaf name"
    matcher = build_matcher(["github.com/d3mlabs/dev", "github.com/someone/dev"])

    Expect "the org/repo form resolves uniquely"
    matcher.resolve("d3mlabs/dev").segments == ["github.com", "d3mlabs", "dev"]
  end

  test "per-segment fuzzy: d3m/d resolves to d3mlabs/dev" do
    Given "repos where only one matches both fuzzy segments"
    matcher = build_matcher(["github.com/d3mlabs/dev", "github.com/someone/dev"])

    Expect "each side of the slash fuzzy-matches its segment"
    matcher.resolve("d3m/d").segments == ["github.com", "d3mlabs", "dev"]
  end

  test "same org/repo under two hosts: org/repo is ambiguous with host/org/repo candidates" do
    Given "the same checkout under github and bitbucket"
    matcher = build_matcher(["github.com/d3mlabs/dev", "bitbucket.org/d3mlabs/dev"])

    When "we resolve org/repo"
    error = assert_raises(Dev::Cd::Matcher::AmbiguousRepoError) { matcher.resolve("d3mlabs/dev") }

    Then "candidates render with their hosts"
    error.candidates == ["bitbucket.org/d3mlabs/dev", "github.com/d3mlabs/dev"]
  end

  test "host/org/repo resolves a two-host collision" do
    Given "the same checkout under github and bitbucket"
    matcher = build_matcher(["github.com/d3mlabs/dev", "bitbucket.org/d3mlabs/dev"])

    Expect "the full host form resolves"
    matcher.resolve("github.com/d3mlabs/dev").segments == ["github.com", "d3mlabs", "dev"]
  end

  test "a fuzzy host segment picks the matching host (b/d3m/dev → bitbucket)" do
    Given "the same checkout under github and bitbucket"
    matcher = build_matcher(["github.com/d3mlabs/dev", "bitbucket.org/d3mlabs/dev"])

    Expect "b fuzzy-matches bitbucket.org but not github.com"
    matcher.resolve("b/d3m/dev").segments == ["bitbucket.org", "d3mlabs", "dev"]
  end

  test "no match raises RepoNotFoundError" do
    Given "a matcher over one repo"
    matcher = build_matcher(["github.com/d3mlabs/dev"])

    When "we resolve a name that matches nothing"
    matcher.resolve("nonexistent")

    Then
    raises Dev::Cd::Matcher::RepoNotFoundError
  end

  test "an exact leaf match beats substring matches instead of being ambiguous" do
    Given "a repo named dev and one merely containing dev"
    matcher = build_matcher(["github.com/d3mlabs/dev", "github.com/d3mlabs/dev-tools"])

    Expect "the exact name wins"
    matcher.resolve("dev").segments == ["github.com", "d3mlabs", "dev"]
  end

  test "a prefix match beats a substring match" do
    Given "one repo starting with the query and one containing it"
    matcher = build_matcher(["github.com/d3mlabs/flowctl", "github.com/d3mlabs/ai-flow"])

    Expect "the prefix match wins"
    matcher.resolve("flow").name == "flowctl"
  end

  test "equal-score matches tie into ambiguity, ordered by path" do
    Given "two repos that both prefix-match the query"
    matcher = build_matcher(["github.com/zzz/devkit", "github.com/aaa/devtools"])

    When "we resolve the shared prefix"
    error = assert_raises(Dev::Cd::Matcher::AmbiguousRepoError) { matcher.resolve("dev") }

    Then "candidates come back in stable path order"
    error.candidates == ["devtools", "devkit"]
  end

  test "candidates with an empty query lists every repo at unique depth" do
    Given "three repos, two sharing a leaf name"
    matcher = build_matcher([
      "github.com/d3mlabs/dev", "github.com/someone/dev", "github.com/d3mlabs/ai-flow",
    ])

    When "we ask for candidates with no query"
    result = matcher.candidates("")

    Then "all repos are listed, duplicates disambiguated"
    result.sort == ["ai-flow", "d3mlabs/dev", "someone/dev"]
  end

  test "candidates filters and ranks by the partial query" do
    Given "repos with distinct leaves"
    matcher = build_matcher([
      "github.com/d3mlabs/dev", "github.com/d3mlabs/devkit", "github.com/d3mlabs/ai-flow",
    ])

    When "we ask for candidates for a partial leaf"
    result = matcher.candidates("dev")

    Then "only matching repos come back, best first, not capped as ambiguity"
    result == ["dev", "devkit"]
  end

  test "candidates renders host-colliding repos at host/org/repo depth" do
    Given "the same checkout under two hosts"
    matcher = build_matcher(["github.com/d3mlabs/dev", "bitbucket.org/d3mlabs/dev"])

    When "we ask for candidates"
    result = matcher.candidates("d3mlabs/dev")

    Then "the host disambiguates each candidate"
    result.sort == ["bitbucket.org/d3mlabs/dev", "github.com/d3mlabs/dev"]
  end

  test "a query deeper than the repo path does not match" do
    Given "a repo two segments deep"
    matcher = build_matcher(["shallow/repo"])

    When "we resolve a three-segment query"
    matcher.resolve("a/b/repo")

    Then
    raises Dev::Cd::Matcher::RepoNotFoundError
  end

  private

  def build_matcher(relative_paths)
    repos = relative_paths.map do |rel|
      Dev::Cd::Repo.new(path: Pathname("/src") / rel, segments: rel.split("/"))
    end
    Dev::Cd::Matcher.new(repos: repos)
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cd"
require "tmpdir"
require "fileutils"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::Cd::MatcherTest < Minitest::Test
  # @param root [String]
  # @param relative [String]
  # @return [Pathname]
  def make_git_repo(root, relative)
    path = Pathname(root) / relative
    FileUtils.mkdir_p(path)
    FileUtils.mkdir_p(path / ".git")
    path
  end

  # @param relative_paths [Array<String>]
  # @return [Array(String, Dev::Cd::Matcher)]
  def build_matcher(*relative_paths)
    dir = Dir.mktmpdir("dev-cd-matcher-")
    relative_paths.each { |rel| make_git_repo(dir, rel) }
    [dir, Dev::Cd::Matcher.new(workspace: Dev::Cd::Workspace.new(root: dir))]
  end

  test "resolve returns the unique leaf match" do
    Given "a single matching checkout"
    dir, matcher = build_matcher("github.com/d3mlabs/widgets")

    Expect
    matcher.resolve("widgets") == Pathname(dir) / "github.com" / "d3mlabs" / "widgets"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "resolve prefers exact over substring" do
    Given "exact and substring leaf names"
    dir, matcher = build_matcher(
      "github.com/d3mlabs/dev",
      "github.com/d3mlabs/devtools",
    )

    Expect "exact wins"
    matcher.resolve("dev") == Pathname(dir) / "github.com" / "d3mlabs" / "dev"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "resolve prefers prefix over substring" do
    Given "prefix and mid-string matches"
    dir, matcher = build_matcher(
      "github.com/d3mlabs/myapp",
      "github.com/d3mlabs/foomyapp",
    )

    Expect
    matcher.resolve("mya") == Pathname(dir) / "github.com" / "d3mlabs" / "myapp"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "resolve raises AmbiguousRepoError for duplicate leaf names" do
    Given "two orgs with the same repo leaf"
    dir, matcher = build_matcher(
      "github.com/d3mlabs/dev",
      "github.com/someone/dev",
    )

    When "resolving the ambiguous leaf"
    matcher.resolve("dev")

    Then
    raises Dev::Cd::Matcher::AmbiguousRepoError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "AmbiguousRepoError lists org/repo candidates sorted by path" do
    Given "two colliding leaves"
    dir, matcher = build_matcher(
      "github.com/zeta/dev",
      "github.com/alpha/dev",
    )

    When "resolving"
    begin
      matcher.resolve("dev")
      flunk "expected AmbiguousRepoError"
    rescue Dev::Cd::Matcher::AmbiguousRepoError => e
      error = e
    end

    Then "candidates are stable and all labels appear in the message"
    error.candidates.map(&:org_repo) == ["alpha/dev", "zeta/dev"]
    error.message.include?("alpha/dev")
    error.message.include?("zeta/dev")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "AmbiguousRepoError lists every tied candidate" do
    Given "more than ten colliding leaves"
    paths = (1..12).map { |n| format("github.com/org%02d/dev", n) }
    expected_labels = (1..12).map { |n| format("org%02d/dev", n) }
    dir, matcher = build_matcher(*paths)

    When "resolving"
    begin
      matcher.resolve("dev")
      flunk "expected AmbiguousRepoError"
    rescue Dev::Cd::Matcher::AmbiguousRepoError => e
      error = e
    end

    Then "the message includes every org/repo, not a truncated suffix"
    error.candidates.map(&:org_repo) == expected_labels
    expected_labels.all? { |label| error.message.include?(label) }
    !error.message.include?("more")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "resolve disambiguates with org/repo" do
    Given "two colliding leaves"
    dir, matcher = build_matcher(
      "github.com/d3mlabs/dev",
      "github.com/someone/dev",
    )

    Expect
    matcher.resolve("d3mlabs/dev") == Pathname(dir) / "github.com" / "d3mlabs" / "dev"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "resolve fuzzy-matches each side of org/repo" do
    Given "d3mlabs/dev"
    dir, matcher = build_matcher("github.com/d3mlabs/dev")

    Expect "d3m/d matches uniquely"
    matcher.resolve("d3m/d") == Pathname(dir) / "github.com" / "d3mlabs" / "dev"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "resolve accepts a longer path suffix under the search root" do
    Given "a github.com layout checkout"
    dir, matcher = build_matcher("github.com/d3mlabs/dev")

    Expect
    matcher.resolve("github.com/d3mlabs/dev") == Pathname(dir) / "github.com" / "d3mlabs" / "dev"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "resolve raises RepoNotFoundError when nothing matches" do
    Given "an unrelated checkout"
    dir, matcher = build_matcher("github.com/d3mlabs/dev")

    When "resolving a missing name"
    matcher.resolve("nope")

    Then
    raises Dev::Cd::Matcher::RepoNotFoundError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "resolve is case-insensitive" do
    Given "a MixedCase leaf"
    dir, matcher = build_matcher("github.com/d3mlabs/MyRepo")

    Expect
    matcher.resolve("myrepo") == Pathname(dir) / "github.com" / "d3mlabs" / "MyRepo"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "complete offers leaf names when unique" do
    Given "unique leaves"
    dir, matcher = build_matcher(
      "github.com/d3mlabs/alpha",
      "github.com/d3mlabs/beta",
    )

    Expect
    matcher.complete("") == ["alpha", "beta"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "complete offers org/repo when the leaf is ambiguous" do
    Given "colliding leaves"
    dir, matcher = build_matcher(
      "github.com/d3mlabs/dev",
      "github.com/someone/dev",
    )

    Expect
    matcher.complete("") == ["d3mlabs/dev", "someone/dev"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "complete filters by prefix" do
    Given "several repos"
    dir, matcher = build_matcher(
      "github.com/d3mlabs/widgets",
      "github.com/d3mlabs/tools",
    )

    Expect
    matcher.complete("wi") == ["widgets"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "complete with a slash prefix uses org/repo forms" do
    Given "a unique leaf that also has an org/repo form"
    dir, matcher = build_matcher("github.com/d3mlabs/widgets")

    Expect "slash switches completion to org/repo"
    matcher.complete("d3mlabs/") == ["d3mlabs/widgets"]

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

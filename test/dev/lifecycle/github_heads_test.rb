# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "json"
require "support/fake_gh"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::GithubHeadsTest < Minitest::Test
  REFS = "repos/{owner}/{repo}/git/matching-refs/tags/v"
  SHA_A = "a" * 40
  SHA_B = "b" * 40
  SHA_C = "c" * 40

  def tag(version)
    Dev::Lifecycle::ReleaseTag.new(version)
  end

  def series(major)
    Dev::Lifecycle::Series.new(major)
  end

  # gh's `--jq .[]` over the paginated listing: one ref object per line.
  def ref_lines(*refs)
    refs.map { |name, sha, type| JSON.generate({ "ref" => "refs/tags/#{name}", "object" => { "sha" => sha, "type" => type || "commit" } }) }.join("\n") + "\n"
  end

  def heads(gh)
    Dev::Lifecycle::GithubHeads.new(gh:)
  end

  test "read lists the forge's v-tags once: the bare-major ones are the series pointers, in series order; the version ones name the release at each commit; latest is gh's" do
    Given
    gh = FakeGh.new
      .answers(["api", "--paginate", REFS], with: ref_lines(["v2", SHA_C], ["v1.2.0", SHA_B], ["v1", SHA_B], ["v1.1.0", SHA_A], ["v2.0.0", SHA_C]))
      .answers(["release", "view"], with: "v2.0.0\n")

    When
    read = heads(gh).read

    Then
    read.pointers == [
      Dev::Lifecycle::GithubHeads::Pointer.new(series: series(1), sha: SHA_B),
      Dev::Lifecycle::GithubHeads::Pointer.new(series: series(2), sha: SHA_C),
    ]
    read.releases == { SHA_B => [tag("1.2.0")], SHA_A => [tag("1.1.0")], SHA_C => [tag("2.0.0")] }
    read.latest == tag("2.0.0")
    read.pointer(series(1)).sha == SHA_B
    read.pointer(series(3)).nil?
    read.newest_series == series(2)
    read.releases_at(SHA_B) == [tag("1.2.0")]
    read.releases_at("d" * 40) == []
    gh.calls.map(&:argv) == [
      ["api", "--paginate", REFS, "--jq", ".[]"],
      ["release", "view", "--json", "tagName", "--jq", ".tagName"],
    ]
  end

  test "a repo with no v-tags and no release has no heads" do
    Given
    gh = FakeGh.new.answers(["api", "--paginate", REFS], with: "").refuses(["release", "view"], with: "release not found")

    When
    read = heads(gh).read

    Then
    read == Dev::Lifecycle::GithubHeads::Heads.new(pointers: [], releases: {}, latest: nil)
    read.newest_series.nil?
  end

  test "an annotated tag names a tag object, not a commit, and is not read; a v-led tag that is no version is nobody's" do
    Given
    gh = FakeGh.new
      .answers(["api", "--paginate", REFS], with: ref_lines(["v1.0.0", SHA_A, "tag"], ["v1", SHA_A], ["vendor-x", SHA_B], ["v1.1.0", SHA_B]))
      .answers(["release", "view"], with: "v1.1.0\n")

    When
    read = heads(gh).read

    Then
    read.pointers.map(&:sha) == [SHA_A]
    read.releases == { SHA_B => [tag("1.1.0")] }
  end

  test "point! moves a series tag to the commit by force; create! makes one where the series had none — the two writes of a deploy" do
    Given
    gh = FakeGh.new.answers(["api", "-X", "PATCH"], with: "{}").answers(["api", "-X", "POST"], with: "{}")

    When
    heads(gh).point!(series(1), SHA_B)
    heads(gh).create!(series(2), SHA_C)

    Then
    gh.calls.map(&:argv) == [
      ["api", "-X", "PATCH", "--input", "-", "repos/{owner}/{repo}/git/refs/tags/v1"],
      ["api", "-X", "POST", "--input", "-", "repos/{owner}/{repo}/git/refs"],
    ]
    gh.posted == [{ "sha" => SHA_B, "force" => true }, { "ref" => "refs/tags/v2", "sha" => SHA_C }]
  end

  test "designate_latest! hands a tag's release the forge's latest designation" do
    Given
    gh = FakeGh.new.answers(["release", "edit"], with: "")

    When
    heads(gh).designate_latest!(tag("1.2.0"))

    Then
    gh.calls.map(&:argv) == [["release", "edit", "v1.2.0", "--latest"]]
  end

  test "a refused #{what} is the heads' error, carrying gh's words" do
    Given
    gh = FakeGh.new.refuses(prefix, with: "HTTP 403: Resource not accessible by integration")
    gh.answers(["api", "--paginate", REFS], with: "") if prefix == ["release", "view"]

    When
    call.call(heads(gh))

    Then
    error = raises(Dev::Lifecycle::GithubHeads::ApiError)
    error.message.include?("Resource not accessible")

    Where
    what                  | prefix                       | call
    "tag listing"         | ["api", "--paginate"]        | ->(heads) { heads.read }
    "latest read"         | ["release", "view"]          | ->(heads) { heads.read }
    "point"               | ["api", "-X", "PATCH"]       | ->(heads) { heads.point!(Dev::Lifecycle::Series.new(1), SHA_A) }
    "create"              | ["api", "-X", "POST"]        | ->(heads) { heads.create!(Dev::Lifecycle::Series.new(1), SHA_A) }
    "latest designation"  | ["release", "edit"]          | ->(heads) { heads.designate_latest!(Dev::Lifecycle::ReleaseTag.new("1.0.0")) }
  end

  test "a listing that is #{what} is refused: the forge did not answer refs" do
    Given
    gh = FakeGh.new.answers(["api", "--paginate", REFS], with: printed)

    When
    heads(gh).read

    Then
    raises(Dev::Lifecycle::GithubHeads::MalformedAnswerError)

    Where
    what                 | printed
    "not JSON"           | "not json\n"
    "not ref objects"    | "[1, 2]\n"
    "a ref without one"  | "{\"object\":{\"type\":\"commit\",\"sha\":\"abc\"}}\n"
  end
end

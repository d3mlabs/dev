# typed: false
# frozen_string_literal: true

require "json"
require "test_helper"
require "dev/stream"
require "dev/stream_head_lookup"

# The gh CLI boundary: each argv answered from a table as [out, err, ok],
# every call recorded. An argv the table does not know is the test's
# mistake, not a gh failure.
class CannedGhExecutor
  attr_reader :calls

  def initialize(answers)
    @answers = answers
    @calls = []
  end

  def capture(*argv, chdir: nil, stdin: nil)
    @calls << argv
    @answers.fetch(argv)
  end
end

transform!(RSpock::AST::Transformation)
class Dev::StreamHeadLookupTest < Minitest::Test
  STREAM = Dev::Stream.parse("d3mlabs/ai-flow@gh ~> 1")
  REF = ["gh", "api", "repos/d3mlabs/ai-flow/git/ref/tags/v1"].freeze
  TAGS = ["gh", "api", "--paginate", "repos/d3mlabs/ai-flow/tags", "--jq", '.[] | "\(.name) \(.commit.sha)"'].freeze
  HEAD = "c0ffee0000000000000000000000000000000001"
  OLDER = "0ddba11000000000000000000000000000000002"

  test "the head is the release tag of the series at the commit the series tag points at — the greatest when several name it" do
    Given "v1 a lightweight tag on the commit v1.3.0 and v1.3.1 both name; v2.0.0 and v1.2.0 elsewhere"
    gh = CannedGhExecutor.new(
      REF => [ref("commit", HEAD), "", true],
      TAGS => [tags("v2.0.0" => OLDER, "v1.3.1" => HEAD, "v1.3.0" => HEAD, "v1.2.0" => OLDER, "v1" => HEAD), "", true],
    )

    When
    head = Dev::StreamHeadLookup.new(executor: gh).head(STREAM)

    Then
    head == Dev::Stream::Head.new(version: "1.3.1", commit: HEAD)
    head.tag == "v1.3.1"
    gh.calls == [REF, TAGS]
  end

  test "an annotated series tag is dereferenced to its commit through the tag object" do
    Given "v1 an annotated tag whose object is the tag, not the commit"
    tag_object = "7a60000000000000000000000000000000000003"
    gh = CannedGhExecutor.new(
      REF => [ref("tag", tag_object), "", true],
      ["gh", "api", "repos/d3mlabs/ai-flow/git/tags/#{tag_object}"] => [JSON.generate("object" => { "sha" => HEAD, "type" => "commit" }), "", true],
      TAGS => [tags("v1.0.0" => HEAD), "", true],
    )

    When
    head = Dev::StreamHeadLookup.new(executor: gh).head(STREAM)

    Then
    head == Dev::Stream::Head.new(version: "1.0.0", commit: HEAD)
  end

  test "a rolled-back head reads as the earlier release: the pointer, not the greatest tag, is the head" do
    Given "v1 moved back to v1.2.0's commit while v1.3.0 exists"
    gh = CannedGhExecutor.new(
      REF => [ref("commit", OLDER), "", true],
      TAGS => [tags("v1.3.0" => HEAD, "v1.2.0" => OLDER), "", true],
    )

    Expect
    Dev::StreamHeadLookup.new(executor: gh).head(STREAM).version == "1.2.0"
  end

  test "no series tag means nothing of the series is deployed: NoHeadError naming the deploy that moves it" do
    Given "gh answering 404 for the ref"
    gh = CannedGhExecutor.new(REF => ["", "gh: Not Found (HTTP 404)", false])

    When
    Dev::StreamHeadLookup.new(executor: gh).head(STREAM)

    Then
    error = raises Dev::StreamHeadLookup::NoHeadError
    error.message.include?("has no head")
    error.message.include?("dev deploy gh --release")
  end

  test "a series tag at a commit no release of the series names is HeadNotReleasedError" do
    Given "v1 on a commit only v2.0.0 names"
    gh = CannedGhExecutor.new(
      REF => [ref("commit", HEAD), "", true],
      TAGS => [tags("v2.0.0" => HEAD, "v1.2.0" => OLDER), "", true],
    )

    When
    Dev::StreamHeadLookup.new(executor: gh).head(STREAM)

    Then
    error = raises Dev::StreamHeadLookup::HeadNotReleasedError
    error.message.include?("no v1.x release tag names")
  end

  test "gh unable to answer is QueryError, not a missing head: #{failing}" do
    Given "gh refusing one of the reads"
    answers = {
      REF => [ref("commit", HEAD), "", true],
      TAGS => [tags("v1.0.0" => HEAD), "", true],
    }
    answers[failing] = ["", "error connecting to api.github.com", false]
    gh = CannedGhExecutor.new(answers)

    When
    Dev::StreamHeadLookup.new(executor: gh).head(STREAM)

    Then
    error = raises Dev::StreamHeadLookup::QueryError
    error.message.include?("error connecting to api.github.com")

    Where
    failing
    REF
    TAGS
  end

  private

  def ref(type, sha)
    JSON.generate("ref" => "refs/tags/v1", "object" => { "sha" => sha, "type" => type })
  end

  def tags(by_name)
    by_name.map { |name, sha| "#{name} #{sha}\n" }.join
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/plan"

transform!(RSpock::AST::Transformation)
class Dev::Plan::MergeTest < Minitest::Test
  BASE = "line one\nline two\nline three\n"

  test "non-overlapping edits merge cleanly" do
    Given "local changed line one, remote changed line three"
    local = "line ONE\nline two\nline three\n"
    remote = "line one\nline two\nline THREE\n"

    When "3-way merging"
    result = Dev::Plan::Merge.three_way(local: local, base: BASE, remote: remote)

    Then "both edits land without conflicts"
    result.conflicts? == false
    result.content == "line ONE\nline two\nline THREE\n"

    Cleanup
    nil
  end

  test "overlapping edits produce conflict markers" do
    Given "both sides changed the same line"
    local = "line 1\nline two\nline three\n"
    remote = "line uno\nline two\nline three\n"

    When "3-way merging"
    result = Dev::Plan::Merge.three_way(local: local, base: BASE, remote: remote)

    Then "the result carries diff3 conflict markers"
    result.conflicts? == true
    result.content.include?("<<<<<<<")
    result.content.include?(">>>>>>>")

    Cleanup
    nil
  end
end

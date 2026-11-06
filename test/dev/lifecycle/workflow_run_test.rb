# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::WorkflowRunTest < Minitest::Test
  def run_with(status:, conclusion: nil)
    Dev::Lifecycle::WorkflowRun.new(id: 42, url: "https://github.com/o/r/actions/runs/42", status:, conclusion:)
  end

  test "a run #{what}: completed? #{completed}, succeeded? #{succeeded}" do
    Expect
    run_with(status:, conclusion:).completed? == completed
    run_with(status:, conclusion:).succeeded? == succeeded

    Where
    what                   | status        | conclusion  | completed | succeeded
    "still queued"         | "queued"      | nil         | false     | false
    "in progress"          | "in_progress" | nil         | false     | false
    "completed green"      | "completed"   | "success"   | true      | true
    "completed red"        | "completed"   | "failure"   | true      | false
    "cancelled"            | "completed"   | "cancelled" | true      | false
  end

  test "runs compare by every field" do
    Expect
    run_with(status: "queued") == run_with(status: "queued")
    run_with(status: "queued").eql?(run_with(status: "queued"))
    run_with(status: "queued").hash == run_with(status: "queued").hash
    run_with(status: "queued") != run_with(status: "completed", conclusion: "success")
    run_with(status: "queued") != Dev::Lifecycle::WorkflowRun.new(id: 43, url: "https://github.com/o/r/actions/runs/42", status: "queued", conclusion: nil)
    run_with(status: "queued") != 42
  end
end

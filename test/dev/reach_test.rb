# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/reach"

transform!(RSpock::AST::Transformation)
class Dev::ReachTest < Minitest::Test
  # Reach is a value: two reaches built from the same repos,
  # workflows and labels are the same fact, however they were built.
  test "two reaches with the same repos, workflows and labels are equal and hash alike" do
    Given
    a = Dev::Reach.new(repos: Set["d3mlabs/snappy"], workflows: Set["ai-flow"], labels: Set["ai-build"])
    b = Dev::Reach.new(repos: Set["d3mlabs/snappy"], workflows: Set["ai-flow"], labels: Set["ai-build"])

    Expect
    a == b
    a.hash == b.hash
  end

  test "a reach differing in #{member} is a different fact" do
    Given
    base = Dev::Reach.new(repos: Set["d3mlabs/snappy"], workflows: Set["ai-flow"], labels: Set["ai-build"])

    Expect
    base != other

    Where
    member      | other
    "repos"     | Dev::Reach.new(repos: Dev::Reach::ALL, workflows: Set["ai-flow"], labels: Set["ai-build"])
    "workflows" | Dev::Reach.new(repos: Set["d3mlabs/snappy"], workflows: Dev::Reach::ANY, labels: Set["ai-build"])
    "labels"    | Dev::Reach.new(repos: Set["d3mlabs/snappy"], workflows: Set["ai-flow"], labels: Set["snappy"])
  end

  test "open when every repo may send jobs, else a selection" do
    Expect
    Dev::Reach.new(repos: Dev::Reach::ALL, workflows: Dev::Reach::ANY, labels: Set["x"]).open?
    !Dev::Reach.new(repos: Set["d3mlabs/snappy"], workflows: Dev::Reach::ANY, labels: Set["x"]).open?
  end

  test "admits a repo's jobs when open or when the selection names it, as GitHub names repos — #{repos.inspect} admits #{repo}: #{admitted}" do
    Expect
    Dev::Reach.new(repos: repos, workflows: Dev::Reach::ANY, labels: Set["x"]).admits?(repo) == admitted

    Where
    repos                    | repo                   | admitted
    Dev::Reach::ALL          | "d3mlabs/anything"     | true
    Set["d3mlabs/Dev"]       | "d3mlabs/dev"          | true
    Set["d3mlabs/dev"]       | "d3mlabs/cellbound-3d" | false
    Set[]                    | "d3mlabs/dev"          | false
  end
end

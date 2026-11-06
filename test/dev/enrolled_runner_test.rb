# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/enrolled_runner"

transform!(RSpock::AST::Transformation)
class Dev::EnrolledRunnerTest < Minitest::Test
  test "the enrolled runner of #{repo} is scoped to the repo and labelled with its name — lowercased, dashes kept" do
    Expect "the one derivation register enrolls by and the lookup asks GitHub by"
    Dev::EnrolledRunner.for(repo) == Dev::EnrolledRunner.new(scope: repo, label: label)

    Where
    repo                      | label
    "d3mlabs/cellbound-3d"    | "cellbound-3d"
    "d3mlabs/unreal-engine"   | "unreal-engine"
    "JPDuchesne/snappy"       | "snappy"
    "D3MLabs/Cellbound-3D"    | "cellbound-3d"
  end

  test "the scope keeps GitHub's spelling: only the label is lowercased" do
    Given
    runner = Dev::EnrolledRunner.for("D3MLabs/Cellbound-3D")

    Expect
    runner.scope == "D3MLabs/Cellbound-3D"
    runner.label == "cellbound-3d"
  end

  test "#{repo.inspect} is not an owner/repo (#{why}) and is refused, naming the shape" do
    When
    Dev::EnrolledRunner.for(repo)

    Then "a typed error, so a bare name never enrolls at (or is looked up at) an org scope by accident"
    error = raises Dev::EnrolledRunner::MalformedRepoError
    error.message.include?(repo)
    error.message.include?("owner/repo")

    Where
    repo                         | why
    "cellbound-3d"               | "no owner"
    ""                           | "empty"
    "d3mlabs/"                   | "no name"
    "/cellbound-3d"              | "empty owner"
    "d3mlabs/cellbound-3d/extra" | "a third segment"
  end

  test "two derivations of one repo are the same value; a different repo is not" do
    Given
    one = Dev::EnrolledRunner.for("d3mlabs/cellbound-3d")
    same = Dev::EnrolledRunner.for("d3mlabs/cellbound-3d")
    other = Dev::EnrolledRunner.for("JPDuchesne/snappy")

    Expect
    one == same
    one.eql?(same)
    one.hash == same.hash
    one != other
    !one.eql?("d3mlabs/cellbound-3d")
  end
end

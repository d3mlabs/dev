# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::StepOutputsTest < Minitest::Test
  def setup
    @dir = Pathname(Dir.mktmpdir("step-outputs-"))
    @file = @dir / "output"
  end

  def teardown
    FileUtils.rm_rf(@dir)
    super
  end

  test "from_env reads GITHUB_OUTPUT: a path is a job, unset or empty is none" do
    Expect
    Dev::Lifecycle::StepOutputs.from_env({ "GITHUB_OUTPUT" => @file.to_s }).active?
    !Dev::Lifecycle::StepOutputs.from_env({}).active?
    !Dev::Lifecycle::StepOutputs.from_env({ "GITHUB_OUTPUT" => "" }).active?
  end

  test "artifact appends the name as one line and the files as a fenced multi-line value, after what the job already wrote" do
    Given
    @file.write("earlier=1\n")

    When
    Dev::Lifecycle::StepOutputs.new(path: @file).artifact("rspock", files: [Pathname("/s/rspock/rspock.gem"), Pathname("/s/rspock/build-id.json")])

    Then
    lines = @file.read.lines(chomp: true)
    lines.fetch(0) == "earlier=1"
    lines.fetch(1) == "artifact=rspock"
    lines.fetch(2).match?(/\Aartifact_files<<dev-\h{16}\z/)
    lines.fetch(3) == "/s/rspock/rspock.gem"
    lines.fetch(4) == "/s/rspock/build-id.json"
    lines.fetch(5) == lines.fetch(2).delete_prefix("artifact_files<<")
    lines.size == 6
  end

  test "one file is one line, no fence" do
    When
    Dev::Lifecycle::StepOutputs.new(path: @file).artifact("rspock", files: [Pathname("/s/rspock/rspock.gem")])

    Then
    @file.read == "artifact=rspock\nartifact_files=/s/rspock/rspock.gem\n"
  end

  test "outside a job nothing is written anywhere" do
    When
    Dev::Lifecycle::StepOutputs.new(path: nil).artifact("rspock", files: [Pathname("/s/rspock/rspock.gem")])

    Then
    @dir.children.empty?
  end
end

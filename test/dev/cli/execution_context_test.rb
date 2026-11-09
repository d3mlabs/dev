# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/execution_context"

transform!(RSpock::AST::Transformation)
class Dev::Cli::ExecutionContextTest < Minitest::Test
  include SorbetHelper

  test "project! unwraps the project half when one exists" do
    Given "a context with a project half"
    project = Dev::Cli::ProjectContext.new(name: "TestProject", root: Pathname.new("/tmp/ctx-test"))
    context = Dev::Cli::ExecutionContext.new(ui: typed_mock(Dev::Ui), project: project)

    Expect "the non-nil project"
    context.project!.equal?(project)
  end

  test "project_images is the project's ProjectImages, one per context" do
    Given "a project half"
    project = Dev::Cli::ProjectContext.new(name: "TestProject", root: Pathname.new("/tmp/ctx-test"))

    Expect
    project.project_images.is_a?(Dev::Cli::ProjectImages)
    project.project_images.equal?(project.project_images)
  end

  test "project! raises ProjectRequiredError outside a project" do
    Given "a context with no project half"
    context = Dev::Cli::ExecutionContext.new(ui: typed_mock(Dev::Ui))

    When "unwrapping the project"
    context.project!

    Then
    raises Dev::Cli::ExecutionContext::ProjectRequiredError
  end
end

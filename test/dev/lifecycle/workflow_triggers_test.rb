# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::WorkflowTriggersTest < Minitest::Test
  SNAPSHOT = "dev/build/cellbound-3d/20261105T173000Z-a1b2c3"

  test "a push trigger #{fires ? "fires" : "stays quiet"} for the snapshot branch when written as: #{on.lines.first.strip}" do
    Given "a project with one workflow"
    root = Pathname(Dir.mktmpdir("workflow-triggers-"))
    write_workflow(root, "ci.yml", on)

    Expect
    Dev::Lifecycle::WorkflowTriggers.new(root:).firing_on_push_to(SNAPSHOT).map(&:to_s) == (fires ? [".github/workflows/ci.yml"] : [])

    Cleanup
    FileUtils.rm_rf(root)

    Where
    on                                                                          | fires
    "on: push\n"                                                                | true
    "on: [push, pull_request]\n"                                                | true
    "on:\n  push:\n  pull_request:\n"                                           | true
    "on:\n  push: {}\n"                                                         | true
    "on:\n  push:\n    paths: ['src/**']\n"                                     | true
    "on:\n  push:\n    branches: ['**']\n"                                      | true
    "on:\n  push:\n    branches: ['dev/build/**']\n"                            | true
    "on:\n  push:\n    branches: ['**', '!dev/build/**', 'dev/build/cellbound-3d/*']\n" | true
    "on:\n  push:\n    branches-ignore: [gh-pages]\n"                           | true
    "on:\n  push:\n    branches: [main]\n"                                      | false
    "on:\n  push:\n    branches: main\n"                                        | false
    "on:\n  push:\n    branches: ['dev/build/*']\n"                             | false
    "on:\n  push:\n    branches: ['**', '!dev/build/**']\n"                     | false
    "on:\n  push:\n    branches-ignore: ['dev/build/**']\n"                     | false
    "on:\n  push:\n    tags: ['v*']\n"                                          | false
    "on:\n  push:\n    tags-ignore: ['nightly']\n"                              | false
    "on:\n  push:\n    branches: [main]\n    tags: ['v*']\n"                    | false
    "on: pull_request\n"                                                        | false
    "on: [pull_request, workflow_dispatch]\n"                                   | false
    "on:\n  workflow_dispatch:\n"                                               | false
    "\"on\":\n  push:\n    branches: [main]\n"                                  | false
    "\"on\": push\n"                                                            | true
  end

  test "GitHub's filter grammar: #{pattern.inspect} against #{name.inspect} is #{matches}" do
    Expect
    Dev::Lifecycle::WorkflowTriggers::FilterPattern.new(pattern).matches?(name) == matches

    Where
    pattern                 | name                        | matches
    "main"                  | "main"                      | true
    "main"                  | "maint"                     | false
    "feature/*"             | "feature/x"                 | true
    "feature/*"             | "feature/x/y"               | false
    "feature/**"            | "feature/x/y"               | true
    "**"                    | "dev/build/r/id"            | true
    "*"                     | "dev/build/r/id"            | false
    "releases/v[0-9]+"      | "releases/v12"              | true
    "releases/v[0-9]+"      | "releases/vx"               | false
    "mai?n"                 | "man"                       | true
    "a\\*b"                 | "a*b"                       | true
    "a\\*b"                 | "axb"                       | false
    "a.b"                   | "axb"                       | false
    "!main"                 | "main"                      | true
  end

  test "a negated pattern is marked as such and matched without its bang" do
    Expect
    Dev::Lifecycle::WorkflowTriggers::FilterPattern.new("!dev/build/**").negated
    !Dev::Lifecycle::WorkflowTriggers::FilterPattern.new("dev/build/**").negated
  end

  test "every workflow is read, .yaml included, and the firing ones are reported in file order" do
    Given "three workflows, two of which would run"
    root = Pathname(Dir.mktmpdir("workflow-triggers-"))
    write_workflow(root, "ci.yml", "on:\n  push:\n    branches: [main]\n")
    write_workflow(root, "docs.yaml", "on: push\n")
    write_workflow(root, "nightly.yml", "on:\n  push:\n  schedule:\n    - cron: '0 0 * * *'\n")

    When
    firing = Dev::Lifecycle::WorkflowTriggers.new(root:).firing_on_push_to(SNAPSHOT)

    Then
    firing.map(&:to_s) == [".github/workflows/docs.yaml", ".github/workflows/nightly.yml"]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a project with no workflows directory has nothing that fires" do
    Given
    root = Pathname(Dir.mktmpdir("workflow-triggers-"))

    Expect
    Dev::Lifecycle::WorkflowTriggers.new(root:).firing_on_push_to(SNAPSHOT) == []

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "the assertion refuses with every firing workflow and both fixes named" do
    Given "a project with an unfiltered push trigger"
    root = Pathname(Dir.mktmpdir("workflow-triggers-"))
    write_workflow(root, "ci.yml", "on: push\n")
    write_workflow(root, "lint.yml", "on:\n  push:\n    branches-ignore: [gh-pages]\n")

    When
    Dev::Lifecycle::WorkflowTriggers.new(root:).assert_none_fire_on_push_to!(SNAPSHOT)

    Then
    error = raises(Dev::Lifecycle::WorkflowTriggers::UnfilteredPushTriggerError)
    error.message.include?("pushing the snapshot branch #{SNAPSHOT} would run .github/workflows/ci.yml, .github/workflows/lint.yml")
    error.message.include?("`on: push: branches: [main]`")
    error.message.include?("`branches-ignore: ['dev/build/**']`")

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "the assertion passes when every push trigger is filtered" do
    Given
    root = Pathname(Dir.mktmpdir("workflow-triggers-"))
    write_workflow(root, "ci.yml", "on:\n  push:\n    branches: [main]\n  pull_request:\n")

    When
    Dev::Lifecycle::WorkflowTriggers.new(root:).assert_none_fire_on_push_to!(SNAPSHOT)

    Then "nothing raised"
    true

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a workflow that is not YAML, or not a mapping, is a MalformedWorkflowError naming the file: #{what}" do
    Given
    root = Pathname(Dir.mktmpdir("workflow-triggers-"))
    write_workflow(root, "broken.yml", body)

    When
    Dev::Lifecycle::WorkflowTriggers.new(root:).firing_on_push_to(SNAPSHOT)

    Then
    error = raises(Dev::Lifecycle::WorkflowTriggers::MalformedWorkflowError)
    error.message.start_with?(".github/workflows/broken.yml: ")

    Cleanup
    FileUtils.rm_rf(root)

    Where
    what            | body
    "not yaml"      | "on: [push\n"
    "not a mapping" | "- push\n"
  end

  private

  def write_workflow(root, name, on_block)
    dir = root / ".github" / "workflows"
    dir.mkpath
    (dir / name).write("name: #{name}\n#{on_block}jobs:\n  noop:\n    runs-on: ubuntu-latest\n    steps: []\n")
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtin_executor"
require "dev/command"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::BuiltinExecutorTest < Minitest::Test
  include SorbetHelper

  # Builtin fake whose body records its invocations, so the test can assert
  # the in-process delegation passed args and context through untouched.
  class FakeBuiltin < Dev::BuiltinCommand
    attr_reader :calls

    def initialize
      @calls = []
      super()
    end

    def desc = "a builtin"

    def category = Dev::Command::Category::Workflow

    def call(args:, context:)
      @calls << [args, context]
    end
  end

  def build_context
    ui = typed_mock(Dev::Cli::Ui)
    Dev::ExecutionContext.new(ui: ui, ruby_version: "4.0.1", project_root: Pathname.new("/tmp/builtin-executor"))
  end

  test "execute runs the builtin's Ruby body in-process with args and context" do
    Given "a builtin fake and the executor"
    builtin = FakeBuiltin.new
    executor = Dev::BuiltinExecutor.new
    context = build_context

    When "executing"
    executor.execute(builtin, args: ["--verbose"], context: context)

    Then "the body received args and context; no child process was involved"
    builtin.calls == [[["--verbose"], context]]
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/command"
require "dev/dispatch"
require "dev/lifecycle_executor"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::LifecycleExecutorTest < Minitest::Test
  include SorbetHelper

  # A verb that records each stage it was asked to run, so a test reads the
  # order and what each stage received. `before` consumes the args into a
  # string env and returns whatever outcome the test wired; the seam
  # raises when asked, standing in for a failed builder.
  class RecordingVerb < Dev::LifecycleCommand
    Env = type_member { { fixed: String } }

    attr_reader :stages

    def initialize(outcome:, seam_error: nil)
      super()
      @outcome = outcome
      @seam_error = seam_error
      @stages = []
    end

    def desc = "a recording verb"

    def before(args:, context:)
      @stages << [:before, args.positionals, context]
      @outcome.call(args.positionals.join(" "))
    end

    def seam(env, context:)
      @stages << [:seam, env, context]
      raise @seam_error if @seam_error
    end

    def after(env, context:)
      @stages << [:after, env, context]
    end
  end

  class BuilderFailed < RuntimeError; end

  def build_context
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Ui),
      project: Dev::ProjectContext.new(name: "cellbound-3d", root: Pathname.new("/tmp/lifecycle-executor")),
    )
  end

  def run_outcome = ->(env) { Dev::Dispatch::Outcome::Run.new(env) }

  def done_outcome = ->(_env) { Dev::Dispatch::Outcome::Done.new }

  test "Run(env): before, then the seam and after with that env — the args reach before only" do
    Given "a verb whose dispatch runs here"
    verb = RecordingVerb.new(outcome: run_outcome)
    context = build_context
    args = Dev::Cli::ParsedArgs.new(words: ["cellbound-3d-win64-dev"], positionals: ["cellbound-3d-win64-dev"])

    When
    Dev::LifecycleExecutor.new.execute(verb, args: args, context: context)

    Then "the three stages ran in order; the seam and after saw the env before resolved, nothing of argv"
    verb.stages == [
      [:before, ["cellbound-3d-win64-dev"], context],
      [:seam, "cellbound-3d-win64-dev", context],
      [:after, "cellbound-3d-win64-dev", context],
    ]
  end

  test "Done: the dispatch ran the verb elsewhere, so neither the seam nor after runs here" do
    Given "a verb whose dispatch resolved remote"
    verb = RecordingVerb.new(outcome: done_outcome)
    context = build_context

    When
    Dev::LifecycleExecutor.new.execute(verb, args: no_args, context: context)

    Then
    verb.stages == [[:before, [], context]]
  end

  test "a failing seam short-circuits after: the error bubbles, the stamp step never runs" do
    Given "a verb whose seam fails"
    verb = RecordingVerb.new(outcome: run_outcome, seam_error: BuilderFailed.new("exit 2"))
    context = build_context

    When
    Dev::LifecycleExecutor.new.execute(verb, args: no_args, context: context)

    Then
    raises BuilderFailed
    verb.stages.map(&:first) == [:before, :seam]
  end
end

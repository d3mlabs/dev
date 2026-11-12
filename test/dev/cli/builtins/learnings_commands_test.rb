# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/builtins/learnings_init_command"
require "dev/cli/builtins/learnings_invariants_command"
require "dev/cli/builtins/learnings_status_command"
require "dev/cli/builtins/learnings_sync_command"
require "fileutils"
require "stringio"
require "support/recording_ui"
require "tmpdir"

# The four `learnings` verbs share one shape (a per-call accessor factory
# fed the context's ui, one verb call), so one Where-driven file covers
# them; `invariants` alone keeps an `out:` — its block is a payload, not
# the Ui's.
transform!(RSpock::AST::Transformation)
class Dev::Cli::Builtins::LearningsCommandsTest < Minitest::Test
  include SorbetHelper

  LEAVES = [
    Dev::Cli::Builtins::LearningsSyncCommand,
    Dev::Cli::Builtins::LearningsStatusCommand,
    Dev::Cli::Builtins::LearningsInvariantsCommand,
    Dev::Cli::Builtins::LearningsInitCommand,
  ].freeze

  test "#{klass} traits: exempt from staleness (host-global), never stamps, workflow section" do
    Given "the builtin"
    command = klass.new(accessor_factory: ->(_ui) { typed_mock(Dev::Learnings::Accessor) })

    Expect "the declarative traits"
    command.staleness_exempt? == true
    command.stamps? == false
    command.category == Dev::Cli::Command::Category::Workflow
    !command.desc.empty?

    Where
    klass     | _
    LEAVES[0] | 0
    LEAVES[1] | 0
    LEAVES[2] | 0
    LEAVES[3] | 0
  end

  test "#{klass} builds the accessor per call over the context's ui and forwards to #{verb} with #{expected_kwargs}" do
    Given "an expecting accessor behind a factory recording the ui it was handed"
    ui = RecordingUi.new
    accessor = typed_mock(Dev::Learnings::Accessor)
    accessor.expects(verb).with(**expected_kwargs).once
    factory_uis = []
    command = klass.new(accessor_factory: lambda { |factory_ui|
      factory_uis << factory_ui
      accessor
    })

    When "calling the leaf in a projectless context"
    command.call(args: parsed_args(command, args), context: build_context(ui))

    Then "the factory was consulted once, with the context's ui"
    factory_uis == [ui]

    Where
    klass     | verb    | args            | expected_kwargs
    LEAVES[0] | :sync   | []              | {}
    LEAVES[1] | :status | []              | {}
    LEAVES[3] | :init   | []              | { org: false, gitignore_only: false }
    LEAVES[3] | :init   | ["--org"]       | { org: true, gitignore_only: false }
    LEAVES[3] | :init   | ["--gitignore"] | { org: false, gitignore_only: true }
  end

  test "invariants hands the accessor its own out — the prompt block is a payload, never the Ui's" do
    Given "an accessor expecting the bare verb"
    out = StringIO.new
    ui = RecordingUi.new
    accessor = typed_mock(Dev::Learnings::Accessor)
    accessor.expects(:invariants).with(out: out).once
    command = LEAVES[2].new(accessor_factory: ->(_ui) { accessor }, out: out)

    When "calling the leaf"
    command.call(args: no_args, context: build_context(ui))

    Then "nothing reached the seam"
    ui.rows == []
  end

  test "#{klass} rejects #{args.inspect} with the accessor's usage error" do
    Given "a leaf whose factory must never be consulted"
    command = klass.new(accessor_factory: ->(_ui) { flunk("accessor built for a malformed argv") })

    When "calling it with a malformed argv"
    command.call(args: parsed_args(command, args), context: build_context)

    Then
    raises Dev::Learnings::Accessor::UsageError

    Where
    klass     | args
    LEAVES[0] | ["extra"]
    LEAVES[1] | ["extra"]
    LEAVES[2] | ["extra"]
    LEAVES[3] | ["--org", "extra"]
    LEAVES[3] | ["--org", "--gitignore"]
  end

  test "the default factory builds a real accessor anchored at the enclosing project" do
    Given "a plain git checkout as cwd and tmpdir-scoped config"
    dir = Dir.mktmpdir("learnings-leaf-default-")
    FileUtils.mkdir_p(File.join(dir, "repo", ".git"))
    saved = { "XDG_CONFIG_HOME" => ENV["XDG_CONFIG_HOME"], "XDG_DATA_HOME" => ENV["XDG_DATA_HOME"] }
    ENV["XDG_CONFIG_HOME"] = File.join(dir, "config")
    ENV["XDG_DATA_HOME"] = File.join(dir, "data")

    When "calling the production factory from inside the checkout"
    accessor = Dir.chdir(File.join(dir, "repo")) do
      Dev::Cli::Builtins::LearningsVerbCommand::DEFAULT_ACCESSOR_FACTORY.call(RecordingUi.new)
    end

    Then "a real accessor comes back"
    accessor.is_a?(Dev::Learnings::Accessor)

    Cleanup
    saved.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    FileUtils.rm_rf(dir)
  end

  private

  def build_context(ui = RecordingUi.new)
    Dev::Cli::ExecutionContext.new(ui: ui)
  end
end

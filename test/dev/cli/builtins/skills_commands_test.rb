# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/builtins/skills_status_command"
require "dev/cli/builtins/skills_sync_command"
require "fileutils"
require "stringio"
require "support/recording_ui"
require "tmpdir"

# The `skills` verbs share one shape (a per-call accessor factory fed the
# context's ui, one verb call), so one Where-driven file covers them;
# `status --json` alone keeps an `out:` — its document is a payload, not
# the Ui's.
transform!(RSpock::AST::Transformation)
class Dev::Cli::Builtins::SkillsCommandsTest < Minitest::Test
  include SorbetHelper

  LEAVES = [
    Dev::Cli::Builtins::SkillsSyncCommand,
    Dev::Cli::Builtins::SkillsStatusCommand,
  ].freeze

  test "#{klass} traits: exempt from staleness (host-global), never stamps, workflow section" do
    Given "the builtin"
    command = klass.new(accessor_factory: ->(_ui) { typed_mock(Dev::Skills::Accessor) })

    Expect "the declarative traits"
    command.staleness_exempt? == true
    command.stamps? == false
    command.category == Dev::Cli::Command::Category::Workflow
    !command.desc.empty?

    Where
    klass     | _
    LEAVES[0] | 0
    LEAVES[1] | 0
  end

  test "#{klass} builds the accessor per call over the context's ui and forwards to #{verb}" do
    Given "an expecting accessor behind a factory recording the ui it was handed"
    ui = RecordingUi.new
    accessor = typed_mock(Dev::Skills::Accessor)
    accessor.expects(verb).with.once
    factory_uis = []
    command = klass.new(accessor_factory: lambda { |factory_ui|
      factory_uis << factory_ui
      accessor
    })

    When "calling the leaf in a projectless context"
    command.call(args: parsed_args(command, command_args), context: build_context(ui))

    Then "the factory was consulted once, with the context's ui"
    factory_uis == [ui]

    Where
    klass     | verb    | command_args
    LEAVES[0] | :sync   | []
    LEAVES[1] | :status | []
  end

  test "status --json hands the accessor its own out — the document is a payload, never the Ui's" do
    Given "an accessor expecting the bare verb"
    out = StringIO.new
    ui = RecordingUi.new
    accessor = typed_mock(Dev::Skills::Accessor)
    accessor.expects(:status_json).with(out: out).once
    command = LEAVES[1].new(accessor_factory: ->(_ui) { accessor }, out: out)

    When "calling the leaf with --json"
    command.call(args: parsed_args(command, ["--json"]), context: build_context(ui))

    Then "nothing reached the seam"
    ui.rows == []
  end

  test "#{klass} rejects #{args.inspect} with the accessor's usage error" do
    Given "a leaf whose factory must never be consulted"
    command = klass.new(accessor_factory: ->(_ui) { flunk("accessor built for a malformed argv") })

    When "calling it with a malformed argv"
    command.call(args: parsed_args(command, args), context: build_context)

    Then
    raises Dev::Skills::Accessor::UsageError

    Where
    klass     | args
    LEAVES[0] | ["extra"]
    LEAVES[1] | ["extra"]
    LEAVES[1] | ["--json", "extra"]
  end

  test "the default factory builds a real accessor over the host's channels for the enclosing project" do
    Given "a plain git checkout as cwd and tmpdir-scoped config"
    dir = Dir.mktmpdir("skills-leaf-default-")
    FileUtils.mkdir_p(File.join(dir, "repo", ".git"))
    saved = { "XDG_CONFIG_HOME" => ENV["XDG_CONFIG_HOME"], "XDG_DATA_HOME" => ENV["XDG_DATA_HOME"] }
    ENV["XDG_CONFIG_HOME"] = File.join(dir, "config")
    ENV["XDG_DATA_HOME"] = File.join(dir, "data")

    When "calling the production factory from inside the checkout"
    accessor = Dir.chdir(File.join(dir, "repo")) do
      Dev::Cli::Builtins::SkillsVerbCommand::DEFAULT_ACCESSOR_FACTORY.call(RecordingUi.new)
    end

    Then "a real accessor comes back"
    accessor.is_a?(Dev::Skills::Accessor)

    Cleanup
    saved.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    FileUtils.rm_rf(dir)
  end

  private

  def build_context(ui = RecordingUi.new)
    Dev::Cli::ExecutionContext.new(ui: ui)
  end
end

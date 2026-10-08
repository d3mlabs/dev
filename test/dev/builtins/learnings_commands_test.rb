# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/learnings_init_command"
require "dev/builtins/learnings_invariants_command"
require "dev/builtins/learnings_status_command"
require "dev/builtins/learnings_sync_command"
require "fileutils"
require "stringio"
require "tmpdir"

# The four `learnings` verbs share one shape (a per-call accessor factory +
# out, one verb call), so one Where-driven file covers them.
transform!(RSpock::AST::Transformation)
class Dev::Builtins::LearningsCommandsTest < Minitest::Test
  include SorbetHelper

  LEAVES = [
    Dev::Builtins::LearningsSyncCommand,
    Dev::Builtins::LearningsStatusCommand,
    Dev::Builtins::LearningsInvariantsCommand,
    Dev::Builtins::LearningsInitCommand,
  ].freeze

  test "#{klass} traits: exempt from staleness (host-global), never stamps, workflow section" do
    Given "the builtin"
    command = klass.new(accessor_factory: -> { typed_mock(Dev::Learnings::Accessor) }, out: StringIO.new)

    Expect "the declarative traits"
    command.staleness_exempt? == true
    command.stamps? == false
    command.category == Dev::Command::Category::Workflow
    !command.desc.empty?

    Where
    klass     | _
    LEAVES[0] | 0
    LEAVES[1] | 0
    LEAVES[2] | 0
    LEAVES[3] | 0
  end

  test "#{klass} builds the accessor per call and forwards to #{verb} with #{expected_kwargs}" do
    Given "an expecting accessor behind a counting factory"
    out = StringIO.new
    accessor = typed_mock(Dev::Learnings::Accessor)
    accessor.expects(verb).with(**{ out: out }.merge(expected_kwargs)).once
    calls = 0
    command = klass.new(accessor_factory: lambda {
      calls += 1
      accessor
    }, out: out)

    When "calling the leaf in a projectless context"
    command.call(args: args, context: build_context)

    Then "the factory was consulted once"
    calls == 1

    Where
    klass     | verb        | args      | expected_kwargs
    LEAVES[0] | :sync       | []        | {}
    LEAVES[1] | :status     | []        | {}
    LEAVES[2] | :invariants | []        | {}
    LEAVES[3] | :init       | []        | { org: false, gitignore_only: false }
    LEAVES[3] | :init       | ["--org"] | { org: true, gitignore_only: false }
    LEAVES[3] | :init       | ["--gitignore"] | { org: false, gitignore_only: true }
  end

  test "#{klass} rejects #{args.inspect} with the accessor's usage error" do
    Given "a leaf whose factory must never be consulted"
    command = klass.new(accessor_factory: -> { flunk("accessor built for a malformed argv") }, out: StringIO.new)

    When "calling it with a malformed argv"
    command.call(args: args, context: build_context)

    Then
    raises Dev::Learnings::Accessor::UsageError

    Where
    klass     | args
    LEAVES[0] | ["extra"]
    LEAVES[1] | ["extra"]
    LEAVES[2] | ["extra"]
    LEAVES[3] | ["--bogus"]
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
    accessor = Dir.chdir(File.join(dir, "repo")) { Dev::Builtins::LearningsVerbCommand::DEFAULT_ACCESSOR_FACTORY.call }

    Then "a real accessor comes back"
    accessor.is_a?(Dev::Learnings::Accessor)

    Cleanup
    saved.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    FileUtils.rm_rf(dir)
  end

  private

  def build_context
    Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui))
  end
end

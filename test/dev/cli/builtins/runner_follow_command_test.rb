# typed: false
# frozen_string_literal: true

require "fileutils"
require "json"
require "test_helper"
require "tmpdir"
require "dev/cli/builtins/runner_follow_command"
require "dev/runner_discovery"
require "dev/stream"
require "dev/stream_follower"

transform!(RSpock::AST::Transformation)
class Dev::Cli::Builtins::RunnerFollowCommandTest < Minitest::Test
  include SorbetHelper

  STREAM = Dev::Stream.parse("d3mlabs/ai-flow@gh ~> 1")

  test "traits: a visible Environment leaf taking the slot's dir, never stamping" do
    Given "the builtin"
    command = Dev::Cli::Builtins::RunnerFollowCommand.new(discovery: Dev::RunnerDiscovery.new(home: Dir.mktmpdir))

    Expect
    command.hidden? == false
    command.category == Dev::Cli::Command::Category::Environment
    command.stamps? == false
    command.synopsis == "<dir>"
    command.positionals.map(&:placeholder) == ["<dir>"]
    command.flags.empty?
    command.desc.include?("job-started hook")
  end

  test "follow <dir> reads the stream the slot's hook records and follows it on the context's Ui" do
    Given "a slot following the stream, and a follower factory recording its Ui"
    home = Dir.mktmpdir
    dir = write_runner(home, "actions-runner-agent", stream: STREAM)
    followed = []
    uis = []
    follower = typed_mock(Dev::StreamFollower)
    follower.expects(:follow!).with { |stream| followed << stream }.returns(Pathname.new("/tmp/tree"))
    ui = typed_mock(Dev::Ui)
    command = Dev::Cli::Builtins::RunnerFollowCommand.new(
      discovery: Dev::RunnerDiscovery.new(home: home),
      follower_factory: ->(given_ui) {
        uis << given_ui
        follower
      },
    )

    When
    command.call(args: parsed_args(command, [dir]), context: Dev::Cli::ExecutionContext.new(ui: ui))

    Then
    followed == [STREAM]
    uis == [ui]
  end

  test "a slot whose hook follows no stream is refused with what makes one follow" do
    Given "a build host's enrollment: no stream recorded"
    home = Dir.mktmpdir
    dir = write_runner(home, "actions-runner", stream: nil)
    command = Dev::Cli::Builtins::RunnerFollowCommand.new(discovery: Dev::RunnerDiscovery.new(home: home), follower_factory: ->(_ui) { flunk("nothing to follow") })

    When
    command.call(args: parsed_args(command, [dir]), context: Dev::Cli::ExecutionContext.new(ui: typed_mock(Dev::Ui)))

    Then
    error = raises Dev::Cli::Builtins::RunnerFollowCommand::NoStreamError
    error.message.include?("follows no stream")
    error.message.include?("dev runner register")
  end

  test "a dir that is no enrollment is refused" do
    Given "an empty dir"
    dir = Dir.mktmpdir
    command = Dev::Cli::Builtins::RunnerFollowCommand.new(discovery: Dev::RunnerDiscovery.new(home: Dir.mktmpdir), follower_factory: ->(_ui) { flunk("nothing to follow") })

    When
    command.call(args: parsed_args(command, [dir]), context: Dev::Cli::ExecutionContext.new(ui: typed_mock(Dev::Ui)))

    Then
    error = raises Dev::Cli::Builtins::RunnerFollowCommand::NoStreamError
    error.message.include?("not a runner enrollment")
  end

  test "no dir is refused: the hook always names one" do
    Given
    command = Dev::Cli::Builtins::RunnerFollowCommand.new(discovery: Dev::RunnerDiscovery.new(home: Dir.mktmpdir), follower_factory: ->(_ui) { flunk("nothing to follow") })

    When
    command.call(args: no_args, context: Dev::Cli::ExecutionContext.new(ui: typed_mock(Dev::Ui)))

    Then
    error = raises Dev::Cli::Builtins::RunnerFollowCommand::MissingDirError
    error.message.include?("dev runner follow <dir>")
  end

  test "completions offer the dirs of the slots that follow a stream, none once a dir is given" do
    Given "a following slot and a build host"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-agent", stream: STREAM)
    write_runner(home, "actions-runner", stream: nil)
    command = Dev::Cli::Builtins::RunnerFollowCommand.new(discovery: Dev::RunnerDiscovery.new(home: home))

    Expect
    command.completions([]) == ["~/actions-runner-agent"]
    command.completions(["~/actions-runner-agent"]) == []
  end

  private

  # A .runner record the way config.sh writes it (UTF-8 BOM + JSON), and
  # the .env register writes when the slot follows a stream.
  def write_runner(home, dir_name, stream:)
    dir = File.join(home, dir_name)
    FileUtils.mkdir_p(dir)
    record = { "agentId" => 1, "agentName" => "host-agent", "gitHubUrl" => "https://github.com/d3mlabs" }
    File.write(File.join(dir, ".runner"), "\uFEFF#{JSON.generate(record)}")
    File.write(File.join(dir, ".env"), "ACTIONS_RUNNER_HOOK_JOB_STARTED=#{dir}/dev-job-started.sh\nDEV_STREAM=#{stream}\n") if stream
    dir
  end
end

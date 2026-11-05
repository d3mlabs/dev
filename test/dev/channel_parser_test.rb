# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/channel_parser"
require "dev/command_parser"
require "dev/environment_ref"
require "dev/lifecycle"
require "support/lifecycle_fixtures"

transform!(RSpock::AST::Transformation)
class Dev::ChannelParserTest < Minitest::Test
  include LifecycleFixtures

  def parser = Dev::ChannelParser.new(command_parser: Dev::CommandParser.new)

  test "every deploy child is a channel: its targets: as accept patterns, its run: as a script publisher, desc and environment as any command's" do
    Given "a deploy entry with two destinations"
    raw = {
      "desc" => "Ship an artifact to a channel",
      "commands" => {
        "staging" => { "desc" => "rsync to the gamebox", "targets" => ["cellbound-3d-win64"], "run" => "./bin/stage", "environment" => "host" },
        "steam" => { "targets" => ["cellbound-3d-steamworks", "cellbound-3d-server-release"], "run" => "./bin/steam-upload" },
      },
    }

    When
    channels = parser.parse_all(raw, all_targets)

    Then
    channels.keys == ["staging", "steam"]
    channels["staging"] == Dev::Lifecycle::Channel.new(
      name: "staging", desc: "rsync to the gamebox",
      accepts: [Dev::Lifecycle::BuildPattern.parse("cellbound-3d-win64", all_targets)],
      publisher: Dev::Lifecycle::PublisherSpec::Script.new(command: "./bin/stage", environment: Dev::EnvironmentRef::Host.new),
    )
    channels["steam"].desc == "(no description)"
    channels["steam"].accepts.map(&:name) == ["cellbound-3d-steamworks", "cellbound-3d-server-release"]
    channels["steam"].publisher == Dev::Lifecycle::PublisherSpec::Script.new(command: "./bin/steam-upload", environment: nil)
  end

  test "no deploy entry means no channel" do
    Expect
    parser.parse_all(nil, all_targets) == {}
  end

  test "channels_declared? recognizes the shape — a deploy child with targets: — and nothing else: #{what}" do
    Expect
    parser.channels_declared?(raw) == declared

    Where
    what                              | raw | declared
    "a channel"                       | { "deploy" => { "commands" => { "staging" => { "targets" => ["x"], "run" => "r" } } } } | true
    "a plain deploy with children"    | { "deploy" => { "commands" => { "staging" => { "run" => "r" } } } }                    | false
    "a plain deploy command"          | { "deploy" => { "run" => "./bin/deploy" } }                                            | false
    "no deploy"                       | { "up" => { "run" => "./bin/setup" } }                                                 | false
    "no commands at all"              | nil                                                                                    | false
  end

  test "a malformed deploy entry is refused with the fix named: #{fault}" do
    When
    parser.parse_all(raw, all_targets)

    Then
    error = raises(error_class)
    error.message.include?(mention)

    Where
    fault                           | raw | error_class | mention
    "a run: on deploy itself"       | { "run" => "./bin/deploy", "commands" => { "s" => { "targets" => ["rspock"], "run" => "r" } } } | Dev::ChannelParser::DeployBodyError | "deploy is derived from its channels"
    "no children"                   | { "desc" => "Ship" }                                                                                | Dev::ChannelParser::NoChannelsError                   | "declares no channel"
    "empty children"                | { "commands" => {} }                                                                                | Dev::ChannelParser::NoChannelsError                   | "declares no channel"
    "a bare string body"            | "./bin/deploy"                                                                                      | Dev::ChannelParser::NoChannelsError                   | "declares no channel"
    "a child named help"            | { "commands" => { "help" => { "targets" => ["rspock"], "run" => "r" } } }                           | Dev::ChannelParser::ReservedChannelNameError          | "'help' is reserved"
    "a child that is a string"      | { "commands" => { "staging" => "./bin/stage" } }                                                    | Dev::ChannelParser::InvalidChannelError               | "channel 'deploy staging': expected a mapping"
    "a child with children"         | { "commands" => { "staging" => { "targets" => ["rspock"], "run" => "r", "commands" => {} } } }      | Dev::ChannelParser::ChannelChildrenError              | "a channel has no subcommands"
    "a child without run:"          | { "commands" => { "staging" => { "targets" => ["rspock"] } } }                                      | Dev::ChannelParser::ChannelProtocolError              | "has no protocol"
    "a child with an empty run:"    | { "commands" => { "staging" => { "targets" => ["rspock"], "run" => "" } } }                         | Dev::ChannelParser::ChannelProtocolError              | "d3mlabs/dev#422"
    "a child without targets:"      | { "commands" => { "staging" => { "run" => "r" } } }                                                 | Dev::ChannelParser::ChannelAcceptsError               | "`targets:` must be a non-empty list"
    "an empty targets: list"        | { "commands" => { "staging" => { "targets" => [], "run" => "r" } } }                                | Dev::ChannelParser::ChannelAcceptsError               | "got []"
    "a targets: string"             | { "commands" => { "staging" => { "targets" => "rspock", "run" => "r" } } }                          | Dev::ChannelParser::ChannelAcceptsError               | "got \"rspock\""
    "a pattern naming no target"    | { "commands" => { "staging" => { "targets" => ["snappy"], "run" => "r" } } }                        | Dev::Lifecycle::BuildPattern::UnknownTargetError      | "snappy"
    "a pattern off the grammar"     | { "commands" => { "staging" => { "targets" => ["cellbound-3d-win64-dev-steam"], "run" => "r" } } }  | Dev::Lifecycle::BuildPattern::TrailingSegmentError    | "steam"
    "an environment off the shape"  | { "commands" => { "staging" => { "targets" => ["rspock"], "run" => "r", "environment" => [1] } } }  | Dev::CommandParser::InvalidEnvironmentError           | "deploy staging"
  end
end

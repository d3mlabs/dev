# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/channel_parser"
require "dev/cli/command_parser"
require "dev/environment_ref"
require "dev/lifecycle"
require "support/lifecycle_fixtures"

transform!(RSpock::AST::Transformation)
class Dev::Cli::ChannelParserTest < Minitest::Test
  include LifecycleFixtures

  def parser = Dev::Cli::ChannelParser.new(command_parser: Dev::Cli::CommandParser.new)

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

  test "a child without run: names the lock's publisher of its name: targets: configures it, desc as any command's (dev#422): #{what}" do
    Given "a deploy entry whose child has no script"
    raw = { "commands" => { "steam" => entry } }

    When
    channels = parser.parse_all(raw, all_targets)

    Then "the channel's protocol is the integration reference, unbound here — the composition root binds it against the lock"
    channels["steam"] == Dev::Lifecycle::Channel.new(
      name: "steam", desc: desc,
      accepts: [Dev::Lifecycle::BuildPattern.parse("cellbound-3d-steamworks", all_targets)],
      publisher: Dev::Lifecycle::PublisherSpec::Integration.new(name: "steam"),
    )
    channels["steam"].publisher.to_s == "publisher: steam"

    Where
    what                | entry                                                                               | desc
    "targets only"      | { "targets" => ["cellbound-3d-steamworks"] }                                        | "(no description)"
    "with a desc"       | { "desc" => "Steam depots", "targets" => ["cellbound-3d-steamworks"] }              | "Steam depots"
    "with an empty run" | { "desc" => "Steam depots", "targets" => ["cellbound-3d-steamworks"], "run" => "" } | "Steam depots"
  end

  test "a lock-published channel's options ride under its own name, keys stringified, and reach the channel verbatim (dev#426)" do
    Given "a steam child configuring its publisher"
    raw = {
      "commands" => {
        "steam" => {
          "targets" => ["cellbound-3d-steamworks"],
          "steam" => { "app" => 480, "depots" => { "cellbound-3d-steamworks" => 481 }, :branches => { "testing" => "beta" } },
        },
      },
    }

    When
    channels = parser.parse_all(raw, all_targets)

    Then "the mapping is carried as declared — the publisher reads it in its own vocabulary"
    channels["steam"].options == { "app" => 480, "depots" => { "cellbound-3d-steamworks" => 481 }, "branches" => { "testing" => "beta" } }
    channels["steam"].publisher == Dev::Lifecycle::PublisherSpec::Integration.new(name: "steam")
  end

  test "publisher options are refused beside a run:, and when they are not a mapping: #{fault}" do
    When
    parser.parse_all({ "commands" => { "steam" => entry } }, all_targets)

    Then
    error = raises Dev::Cli::ChannelParser::ChannelOptionsError
    error.message.include?(mention)

    Where
    fault                 | entry                                                                            | mention
    "options with a run:" | { "targets" => ["rspock"], "run" => "./bin/steam", "steam" => { "app" => 480 } } | "declares `steam:` options beside `run:`"
    "a scalar"            | { "targets" => ["rspock"], "steam" => 480 }                                      | "`steam:` must be a mapping of the steam publisher's options, got 480"
    "a list"              | { "targets" => ["rspock"], "steam" => [480] }                                    | "`steam:` must be a mapping of the steam publisher's options, got [480]"
  end

  test "no deploy entry means no channel" do
    Expect
    parser.parse_all(nil, all_targets) == {}
  end

  test "channels_declared? recognizes the shape — a deploy child with targets: — and nothing else: #{what}" do
    Expect
    parser.channels_declared?(raw) == declared

    Where
    what                           | raw                                                                                     | declared
    "a channel"                    | { "deploy" => { "commands" => { "staging" => { "targets" => ["x"], "run" => "r" } } } } | true
    "a plain deploy with children" | { "deploy" => { "commands" => { "staging" => { "run" => "r" } } } }                     | false
    "a plain deploy command"       | { "deploy" => { "run" => "./bin/deploy" } }                                             | false
    "no deploy"                    | { "up" => { "run" => "./bin/setup" } }                                                  | false
    "no commands at all"           | nil                                                                                     | false
  end

  test "a malformed deploy entry is refused with the fix named: #{fault}" do
    When
    parser.parse_all(raw, all_targets)

    Then
    error = raises(error_class)
    error.message.include?(mention)

    Where
    fault                          | raw                                                                                                | error_class                                        | mention
    "a run: on deploy itself"      | { "run" => "./bin/deploy", "commands" => { "s" => { "targets" => ["rspock"], "run" => "r" } } }    | Dev::Cli::ChannelParser::DeployBodyError           | "deploy is derived from its channels"
    "no children"                  | { "desc" => "Ship" }                                                                               | Dev::Cli::ChannelParser::NoChannelsError           | "declares no channel"
    "empty children"               | { "commands" => {} }                                                                               | Dev::Cli::ChannelParser::NoChannelsError           | "declares no channel"
    "a bare string body"           | "./bin/deploy"                                                                                     | Dev::Cli::ChannelParser::NoChannelsError           | "declares no channel"
    "a child named help"           | { "commands" => { "help" => { "targets" => ["rspock"], "run" => "r" } } }                          | Dev::Cli::ChannelParser::ReservedChannelNameError  | "'help' is reserved"
    "a child named status"         | { "commands" => { "status" => { "targets" => ["rspock"], "run" => "r" } } }                        | Dev::Cli::ChannelParser::ReservedChannelNameError  | "'status' is reserved"
    "a child named releases"       | { "commands" => { "releases" => { "targets" => ["rspock"], "run" => "r" } } }                      | Dev::Cli::ChannelParser::ReservedChannelNameError  | "'releases' is reserved"
    "a child that is a string"     | { "commands" => { "staging" => "./bin/stage" } }                                                   | Dev::Cli::ChannelParser::InvalidChannelError       | "channel 'deploy staging': expected a mapping"
    "a child with children"        | { "commands" => { "staging" => { "targets" => ["rspock"], "run" => "r", "commands" => {} } } }     | Dev::Cli::ChannelParser::ChannelChildrenError      | "a channel has no subcommands"
    "an environment: without run:" | { "commands" => { "steam" => { "targets" => ["rspock"], "environment" => "host" } } }              | Dev::Cli::ChannelParser::ChannelEnvironmentError   | "declares `environment:` without `run:`"
    "a child without targets:"     | { "commands" => { "staging" => { "run" => "r" } } }                                                | Dev::Cli::ChannelParser::ChannelAcceptsError       | "`targets:` must be a non-empty list"
    "a child with neither"         | { "commands" => { "steam" => { "desc" => "Steam" } } }                                             | Dev::Cli::ChannelParser::ChannelAcceptsError       | "`targets:` must be a non-empty list"
    "an empty targets: list"       | { "commands" => { "staging" => { "targets" => [], "run" => "r" } } }                               | Dev::Cli::ChannelParser::ChannelAcceptsError       | "got []"
    "a targets: string"            | { "commands" => { "staging" => { "targets" => "rspock", "run" => "r" } } }                         | Dev::Cli::ChannelParser::ChannelAcceptsError       | "got \"rspock\""
    "a pattern naming no target"   | { "commands" => { "staging" => { "targets" => ["snappy"], "run" => "r" } } }                       | Dev::Lifecycle::BuildPattern::UnknownTargetError   | "snappy"
    "a pattern off the grammar"    | { "commands" => { "staging" => { "targets" => ["cellbound-3d-win64-dev-steam"], "run" => "r" } } } | Dev::Lifecycle::BuildPattern::TrailingSegmentError | "steam"
    "an environment off the shape" | { "commands" => { "staging" => { "targets" => ["rspock"], "run" => "r", "environment" => [1] } } } | Dev::Cli::CommandParser::InvalidEnvironmentError   | "deploy staging"
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/channel_binder"
require "dev/lifecycle"
require "support/lifecycle_fixtures"
require "support/recording_publisher"

transform!(RSpock::AST::Transformation)
class Dev::Cli::ChannelBinderTest < Minitest::Test
  include LifecycleFixtures

  SCRIPT = Dev::Lifecycle::PublisherSpec::Script
  INTEGRATION = Dev::Lifecycle::PublisherSpec::Integration

  def channel(name, publisher, pattern = "cellbound-3d")
    Dev::Lifecycle::Channel.new(name:, desc: name, accepts: [Dev::Lifecycle::BuildPattern.parse(pattern, all_targets)], publisher:)
  end

  REACH = { "steam" => %i[steam], "brew" => %i[brew ruby] }.freeze

  def binder(*contributed, targets: all_targets, reach: REACH)
    Dev::Cli::ChannelBinder.new(publishers: contributed.to_h { |name| [name, RecordingPublisher.new] }, reach:, targets:)
  end

  test "a declared channel without run: configures the lock's publisher of its name: its targets: stay, the protocol is the integration's" do
    Given
    steam = channel("steam", INTEGRATION.new(name: "steam"), "cellbound-3d-steamworks")

    When
    bound = binder("steam").bind({ "steam" => steam })

    Then
    bound == { "steam" => steam }
  end

  test "a declared channel with run: replaces the lock's publisher of its name: the script is the protocol" do
    Given
    steam = channel("steam", SCRIPT.new(command: "./bin/steam-upload"))

    When
    bound = binder("steam").bind({ "steam" => steam })

    Then
    bound == { "steam" => steam }
  end

  test "a contributed channel the project does not declare appears after the declared ones, over every packageable build" do
    Given
    staging = channel("staging", SCRIPT.new(command: "./bin/stage"))

    When
    bound = binder("steam", "brew").bind({ "staging" => staging })

    Then "registry order after declaration order"
    bound.keys == ["staging", "steam", "brew"]
    bound["staging"] == staging
    bound["steam"].desc == "Ship through the lock's steam publisher"
    bound["steam"].accepts.map(&:name) == ["cellbound-3d", "cellbound-3d-steamworks", "cellbound-3d-server", "rspock"]
    bound["steam"].publisher == INTEGRATION.new(name: "steam")
    bound["brew"].publisher == INTEGRATION.new(name: "brew")
  end

  test "a contributed channel over a project with nothing packageable does not appear: a channel accepting nothing has no meaning" do
    Given
    none = Dev::Lifecycle::Target.new(name: "docs", packager: Dev::Lifecycle::PackagerSpec::None.new)
    gem = gem_target

    Expect
    binder("steam", targets: [none]).bind({}) == {}
    binder("steam", targets: [none, gem]).bind({}).fetch("steam").accepts.map(&:name) == ["rspock"]
  end

  test "no channels on either side is no channels" do
    Expect
    binder.bind({}) == {}
  end

  test "a declared channel with neither run: nor a contributed publisher of its name binds with a fault that says why and what to do, and nothing else is refused (dev#509): #{what}" do
    Given
    channel = channel(name, INTEGRATION.new(name: name))

    When
    bound = binder(*contributed, reach:).bind({ name => channel })
    faults = binder(*contributed, reach:).faults({ name => channel })

    Then "the channel is in the set as declared; the fault is its reason, the summary its cause"
    bound.fetch(name).equal?(channel)
    faults.keys == [name]
    faults.fetch(name).summary == summary
    faults.fetch(name).message == "channel 'deploy #{name}' has no protocol: it declares no `run:` and #{summary} — #{fix}, " \
      "or declare `run:` (a script shipping `$DEV_ARTIFACT`) (d3mlabs/dev#192)"

    Where
    what                                        | name    | contributed | reach  | summary                                   | fix
    "this dev ships no such publisher"          | "brew"  | []          | {}     | "this dev ships no `brew` publisher"      | "`dev up` once a release ships it"
    "this dev ships it, the lock pins no type"  | "brew"  | []          | REACH  | "deps.lock pins none of `brew`, `ruby`"   | "depend on one in dependencies.rb and `dev deps update`"
    "same, other publishers contributed"        | "steam" | ["brew"]    | REACH  | "deps.lock pins no `steam`"               | "depend on one in dependencies.rb and `dev deps update`"
  end

  test "channels with a protocol have no fault" do
    Given
    steam = channel("steam", INTEGRATION.new(name: "steam"))
    staging = channel("staging", SCRIPT.new(command: "./bin/stage"))

    Expect
    binder("steam").faults({ "steam" => steam, "staging" => staging }) == {}
  end
end

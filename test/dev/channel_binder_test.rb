# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/channel_binder"
require "dev/lifecycle"
require "support/lifecycle_fixtures"
require "support/recording_publisher"

transform!(RSpock::AST::Transformation)
class Dev::ChannelBinderTest < Minitest::Test
  include LifecycleFixtures

  SCRIPT = Dev::Lifecycle::PublisherSpec::Script
  INTEGRATION = Dev::Lifecycle::PublisherSpec::Integration

  def channel(name, publisher, pattern = "cellbound-3d")
    Dev::Lifecycle::Channel.new(name:, desc: name, accepts: [Dev::Lifecycle::BuildPattern.parse(pattern, all_targets)], publisher:)
  end

  def binder(*contributed, targets: all_targets)
    Dev::ChannelBinder.new(publishers: contributed.to_h { |name| [name, RecordingPublisher.new] }, targets:)
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

  test "a declared channel with neither run: nor a contributed publisher of its name is refused at load, naming both fixes: #{what}" do
    Given
    steam = channel("steam", INTEGRATION.new(name: "steam"))

    When
    binder(*contributed).bind({ "steam" => steam })

    Then
    error = raises Dev::ChannelBinder::ChannelProtocolError
    error.message.include?("channel 'deploy steam' has no protocol")
    error.message.include?("the lock contributes no `steam` publisher (it contributes: #{listed})")
    error.message.include?("declare `run:`")
    error.message.include?("dependencies.rb (d3mlabs/dev#192)")

    Where
    what                        | contributed | listed
    "an empty lock"             | []          | "none"
    "a lock contributing other" | ["brew"]    | "brew"
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/steam_channel_options"
require "dev/lifecycle"
require "support/lifecycle_fixtures"

transform!(RSpock::AST::Transformation)
class Dev::Deps::SteamChannelOptionsTest < Minitest::Test
  include LifecycleFixtures

  TRACK = Dev::Lifecycle::Track

  def channel(options, accepts: ["cellbound-3d-steamworks", "cellbound-3d-server"])
    Dev::Lifecycle::Channel.new(
      name: "steam", accepts: accepts.map { |pattern| Dev::Lifecycle::BuildPattern.parse(pattern, all_targets) },
      publisher: Dev::Lifecycle::PublisherSpec::Integration.new(name: "steam"), options:,
    )
  end

  def pattern(name)
    Dev::Lifecycle::BuildPattern.parse(name, all_targets)
  end

  test "parse reads the app, a depot per pattern and the branches, defaulting testing to beta and live to default" do
    When
    options = Dev::Deps::SteamChannelOptions.parse(channel({ "app" => 480, "depots" => { "cellbound-3d-steamworks" => 481, "cellbound-3d-server" => "482" } }))

    Then "ids arrive as integers however YAML spelt them; the patterns are parsed against the accepted targets"
    options.app == 480
    options.depots == { pattern("cellbound-3d-steamworks") => 481, pattern("cellbound-3d-server") => 482 }
    options.branches == { TRACK::Testing => "beta", TRACK::Live => "default" }
    options.branch_for(TRACK::Testing) == "beta"
    options.default_branch?(options.branch_for(TRACK::Live))
    !options.default_branch?("beta")
  end

  test "branches: overrides a track's branch and leaves the other at its default" do
    When
    options = Dev::Deps::SteamChannelOptions.parse(channel({ "app" => 480, "depots" => { "cellbound-3d-steamworks" => 481 }, "branches" => { "testing" => "nightly" } }))

    Then
    options.branches == { TRACK::Testing => "nightly", TRACK::Live => "default" }
  end

  test "depot_for is the one depot whose pattern the build matches" do
    Given
    options = Dev::Deps::SteamChannelOptions.parse(channel({
      "app" => 480,
      "depots" => { "cellbound-3d-steamworks-win64" => 481, "cellbound-3d-server-linux64" => 482 },
    }))

    Expect
    options.depot_for(build("cellbound-3d-steamworks-win64-release")) == 481
    options.depot_for(build("cellbound-3d-server-linux64-dev")) == 482
  end

  test "depot_for refuses a build no depot takes" do
    Given
    options = Dev::Deps::SteamChannelOptions.parse(channel({ "app" => 480, "depots" => { "cellbound-3d-steamworks" => 481 } }))

    When
    options.depot_for(build("cellbound-3d-server-linux64-dev"))

    Then
    error = raises Dev::Deps::SteamChannelOptions::NoDepotError
    error.message == "no depot for cellbound-3d-server-linux64-dev: `steam: depots:` names cellbound-3d-steamworks — add a DepotID for it"
  end

  test "depot_for refuses a build two depots claim" do
    Given
    options = Dev::Deps::SteamChannelOptions.parse(channel({
      "app" => 480,
      "depots" => { "cellbound-3d-steamworks" => 481, "cellbound-3d-steamworks-win64" => 483 },
    }))

    When
    options.depot_for(build("cellbound-3d-steamworks-win64-release"))

    Then
    error = raises Dev::Deps::SteamChannelOptions::AmbiguousDepotError
    error.message == "cellbound-3d-steamworks-win64-release matches 2 depot patterns (cellbound-3d-steamworks, " \
      "cellbound-3d-steamworks-win64) — make `steam: depots:` name one depot per build"
  end

  test "parse refuses options missing a key the publisher needs" do
    When
    Dev::Deps::SteamChannelOptions.parse(channel(options))

    Then
    error = raises Dev::Deps::SteamChannelOptions::MissingOptionError
    error.message.start_with?("channel 'deploy steam': `steam: #{key}:` is missing")

    Where
    options                                              | key
    {}                                                   | "depots"
    { "depots" => { "cellbound-3d-steamworks" => 481 } } | "app"
  end

  test "parse refuses a value of the wrong shape, naming the key" do
    When
    Dev::Deps::SteamChannelOptions.parse(channel(options))

    Then
    error = raises Dev::Deps::SteamChannelOptions::InvalidOptionError
    error.message.start_with?("channel 'deploy steam': `steam: #{key}:` must")

    Where
    options                                                                                   | key
    { "app" => 480, "depots" => [] }                                                          | "depots"
    { "app" => 480, "depots" => {} }                                                          | "depots"
    { "app" => 480, "depots" => { "cellbound-3d-steamworks" => "four-eighty-one" } }          | "depots: cellbound-3d-steamworks"
    { "app" => 480, "depots" => { "cellbound-3d-steamworks" => 0 } }                          | "depots: cellbound-3d-steamworks"
    { "app" => "spacewar", "depots" => { "cellbound-3d-steamworks" => 481 } }                 | "app"
    { "app" => 480, "depots" => { "cellbound-3d-steamworks" => 481 }, "branches" => "beta" }  | "branches"
    { "app" => 480, "depots" => { "cellbound-3d-steamworks" => 481 }, "branches" => { "testing" => "" } } | "branches"
  end

  test "a depot pattern no accepted target spells, or a branch keyed by no track, fails in the grammar's own words" do
    When
    Dev::Deps::SteamChannelOptions.parse(channel(options))

    Then
    raises error

    Where
    options                                                                                          | error
    { "app" => 480, "depots" => { "rspock" => 481 } }                                                | Dev::Lifecycle::BuildPattern::UnknownTargetError
    { "app" => 480, "depots" => { "cellbound-3d-steamworks" => 481 }, "branches" => { "qa" => "b" } } | Dev::Lifecycle::UnknownTrackError
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "support/lifecycle_fixtures"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::BuildPatternTest < Minitest::Test
  include LifecycleFixtures

  test "a pattern expands over the axes it omits, and is fully qualified only when every declared axis is given: #{name}" do
    When
    pattern = Dev::Lifecycle::BuildPattern.parse(name, all_targets)

    Then
    pattern.name == name
    pattern.builds.map(&:name) == expanded
    pattern.fully_qualified? == fully

    Where
    name                                    | fully | expanded
    "cellbound-3d"                          | false | ["cellbound-3d-win64-dev", "cellbound-3d-win64-release", "cellbound-3d-linux64-dev", "cellbound-3d-linux64-release"]
    "cellbound-3d-win64"                    | false | ["cellbound-3d-win64-dev", "cellbound-3d-win64-release"]
    "cellbound-3d-release"                  | false | ["cellbound-3d-win64-release", "cellbound-3d-linux64-release"]
    "cellbound-3d-linux64-dev"              | true  | ["cellbound-3d-linux64-dev"]
    "cellbound-3d-steamworks"               | false | ["cellbound-3d-steamworks-win64-release"]
    "cellbound-3d-steamworks-win64-release" | true  | ["cellbound-3d-steamworks-win64-release"]
    "rspock"                                | true  | ["rspock"]
  end

  test "the longest declared target prefix wins, so a longer-named sibling is never read as the shorter target plus segments" do
    When
    pattern = Dev::Lifecycle::BuildPattern.parse("cellbound-3d-steamworks-win64", all_targets)

    Then
    pattern.target == steamworks_target
    pattern.platform == PLATFORM::Win64
    pattern.config.nil?
  end

  test "build names the one build of a fully-qualified pattern" do
    Expect
    Dev::Lifecycle::BuildPattern.parse("cellbound-3d-steamworks-win64-release", all_targets).build.name ==
      "cellbound-3d-steamworks-win64-release"
    Dev::Lifecycle::BuildPattern.parse("rspock", all_targets).build.name == "rspock"
  end

  test "build refuses a pattern that omits a declared axis — even one spanning a single build — listing what it spans: #{name}" do
    When
    Dev::Lifecycle::BuildPattern.parse(name, all_targets).build

    Then
    error = raises(Dev::Lifecycle::BuildPattern::PartialPatternError)
    error.message.include?(message)

    Where
    name                      | message
    "cellbound-3d-dev"        | "'cellbound-3d-dev' omits a declared axis: it is a pattern over 2 builds (cellbound-3d-win64-dev, cellbound-3d-linux64-dev)"
    "cellbound-3d-steamworks" | "'cellbound-3d-steamworks' omits a declared axis: it is a pattern over 1 build (cellbound-3d-steamworks-win64-release)"
  end

  test "default_build fills each omitted axis with the target's first declared value: #{name}" do
    Expect
    Dev::Lifecycle::BuildPattern.parse(name, all_targets).default_build.name == default

    Where
    name                    | default
    "cellbound-3d"          | "cellbound-3d-win64-dev"
    "cellbound-3d-linux64"  | "cellbound-3d-linux64-dev"
    "cellbound-3d-release"  | "cellbound-3d-win64-release"
    "cellbound-3d-server"   | "cellbound-3d-server-linux64-dev"
    "rspock"                | "rspock"
  end

  test "matches? admits a build of the same target whose given axes agree" do
    Given
    pattern = Dev::Lifecycle::BuildPattern.parse("cellbound-3d-release", all_targets)

    Expect
    pattern.matches?(build("cellbound-3d-win64-release"))
    pattern.matches?(build("cellbound-3d-linux64-release"))
    !pattern.matches?(build("cellbound-3d-win64-dev"))
    !pattern.matches?(build("cellbound-3d-steamworks-win64-release"))
  end

  test "parse names the declared targets when the name starts with none of them" do
    When
    Dev::Lifecycle::BuildPattern.parse("opencell-win64", all_targets)

    Then
    error = raises(Dev::Lifecycle::BuildPattern::UnknownTargetError)
    error.message.include?("'opencell-win64' names no declared target")
    error.message.include?("cellbound-3d, cellbound-3d-steamworks, cellbound-3d-server, rspock")
  end

  test "parse refuses an axis value the target does not declare — or any value, for a target without the axis: #{name}" do
    When
    Dev::Lifecycle::BuildPattern.parse(name, all_targets)

    Then
    error = raises(error_class)
    error.message.include?(message)

    Where
    name                          | error_class                                             | message
    "cellbound-3d-macos"          | Dev::Lifecycle::BuildPattern::UnsupportedPlatformError  | "does not declare platform 'macos' (declared: win64, linux64)"
    "rspock-win64"                | Dev::Lifecycle::BuildPattern::UnsupportedPlatformError  | "target 'rspock' declares no platforms"
    "cellbound-3d-steamworks-dev" | Dev::Lifecycle::BuildPattern::UnsupportedConfigError    | "does not declare config 'dev' (declared: release)"
    "rspock-release"              | Dev::Lifecycle::BuildPattern::UnsupportedConfigError    | "target 'rspock' declares no configs"
  end

  test "parse refuses anything after the config segment, stating the target's grammar: #{name}" do
    When
    Dev::Lifecycle::BuildPattern.parse(name, all_targets)

    Then
    error = raises(Dev::Lifecycle::BuildPattern::TrailingSegmentError)
    error.message.include?("'#{trailing}' follows")
    error.message.include?(grammar)

    Where
    name                             | trailing      | grammar
    "cellbound-3d-win64-dev-steam"   | "steam"       | "cellbound-3d-<win64|linux64>-<dev|release>"
    "cellbound-3d-dev-win64"         | "win64"       | "cellbound-3d-<win64|linux64>-<dev|release>"
    "cellbound-3d-foo-bar"           | "foo-bar"     | "cellbound-3d-<win64|linux64>-<dev|release>"
    "rspock-gem"                     | "gem"         | "the grammar is rspock"
  end

  test "patterns are values" do
    Expect
    Dev::Lifecycle::BuildPattern.parse("cellbound-3d-win64", all_targets) ==
      Dev::Lifecycle::BuildPattern.parse("cellbound-3d-win64", all_targets)
    Dev::Lifecycle::BuildPattern.parse("cellbound-3d-win64", all_targets).hash ==
      Dev::Lifecycle::BuildPattern.parse("cellbound-3d-win64", all_targets).hash
    Dev::Lifecycle::BuildPattern.parse("cellbound-3d-win64", all_targets) !=
      Dev::Lifecycle::BuildPattern.parse("cellbound-3d", all_targets)
    Dev::Lifecycle::BuildPattern.parse("cellbound-3d-win64", all_targets).to_s == "cellbound-3d-win64"
  end
end

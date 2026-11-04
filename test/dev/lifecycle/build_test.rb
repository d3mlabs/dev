# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "support/lifecycle_fixtures"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::BuildTest < Minitest::Test
  include LifecycleFixtures

  test "a build names itself as <target>[-<platform>[-<config>]], each segment present iff the target declares the axis" do
    Expect
    Dev::Lifecycle::Build.new(
      target: client_target, platform: PLATFORM::Linux64, config: CONFIG::Release,
    ).name == "cellbound-3d-linux64-release"
    Dev::Lifecycle::Build.new(target: gem_target).name == "rspock"
    Dev::Lifecycle::Build.new(target: gem_target).to_s == "rspock"
  end

  test "Build.parse reads a fully-qualified name back through the grammar: #{name}" do
    When
    parsed = Dev::Lifecycle::Build.parse(name, all_targets)

    Then
    parsed.name == name
    parsed.target.name == target_name
    [parsed.platform, parsed.config] == [platform, config]

    Where
    name                                    | target_name               | platform                                 | config
    "cellbound-3d-win64-dev"                | "cellbound-3d"            | LifecycleFixtures::PLATFORM::Win64       | LifecycleFixtures::CONFIG::Development
    "cellbound-3d-linux64-release"          | "cellbound-3d"            | LifecycleFixtures::PLATFORM::Linux64     | LifecycleFixtures::CONFIG::Release
    "cellbound-3d-steamworks-win64-release" | "cellbound-3d-steamworks" | LifecycleFixtures::PLATFORM::Win64       | LifecycleFixtures::CONFIG::Release
    "cellbound-3d-server-linux64-dev"       | "cellbound-3d-server"     | LifecycleFixtures::PLATFORM::Linux64     | LifecycleFixtures::CONFIG::Development
    "rspock"                                | "rspock"                  | nil                                      | nil
  end

  test "Build.parse refuses a pattern that omits a declared axis" do
    When
    Dev::Lifecycle::Build.parse("cellbound-3d-win64", all_targets)

    Then
    error = raises(Dev::Lifecycle::BuildPattern::PartialPatternError)
    error.message.include?("over 2 builds (cellbound-3d-win64-dev, cellbound-3d-win64-release)")
  end

  test "an axis is present exactly when the target declares it, and holds one of its values: #{target_name} × #{platform_id.inspect} × #{config_id.inspect}" do
    Given
    target = all_targets.find { |candidate| candidate.name == target_name }

    When
    Dev::Lifecycle::Build.new(
      target: target,
      platform: platform_id && PLATFORM.parse(platform_id),
      config: config_id && CONFIG.parse(config_id),
    )

    Then
    error = raises(error_class)
    error.message.include?(message)

    Where
    target_name               | platform_id | config_id | error_class                                  | message
    "cellbound-3d"            | nil         | "release" | Dev::Lifecycle::Build::PlatformMismatchError | "declares platforms (win64, linux64)"
    "rspock"                  | "win64"     | nil       | Dev::Lifecycle::Build::PlatformMismatchError | "declares no platforms"
    "cellbound-3d-server"     | "win64"     | "release" | Dev::Lifecycle::Build::PlatformMismatchError | "does not declare platform 'win64' (declared: linux64)"
    "cellbound-3d"            | "win64"     | nil       | Dev::Lifecycle::Build::ConfigMismatchError   | "declares configs (dev, release)"
    "rspock"                  | nil         | "release" | Dev::Lifecycle::Build::ConfigMismatchError   | "declares no configs"
    "cellbound-3d-steamworks" | "win64"     | "debug"   | Dev::Lifecycle::Build::ConfigMismatchError   | "does not declare config 'debug' (declared: release)"
  end

  test "builds are values: equal by target and axes, usable as hash keys" do
    Expect
    build("cellbound-3d-win64-dev") == build("cellbound-3d-win64-dev")
    build("cellbound-3d-win64-dev").hash == build("cellbound-3d-win64-dev").hash
    build("cellbound-3d-win64-dev") != build("cellbound-3d-win64-release")
    { build("rspock") => 1 }.key?(build("rspock"))
  end
end

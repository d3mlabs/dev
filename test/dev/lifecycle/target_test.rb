# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "support/lifecycle_fixtures"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::TargetTest < Minitest::Test
  include LifecycleFixtures

  test "a target declares its axes; each present axis contributes a segment to every build" do
    Given
    target = client_target

    Expect "the cross product, platforms outer, in declaration order"
    target.platforms?
    target.configs?
    target.builds.map(&:name) == [
      "cellbound-3d-win64-dev", "cellbound-3d-win64-release",
      "cellbound-3d-linux64-dev", "cellbound-3d-linux64-release",
    ]
    target.default_build.name == "cellbound-3d-win64-dev"
    target.to_s == "cellbound-3d"
  end

  test "a target with no axes is its own single build, named as the target" do
    Given
    target = gem_target

    Expect
    !target.platforms?
    !target.configs?
    target.builds.map(&:name) == ["rspock"]
    target.default_build == Dev::Lifecycle::Build.new(target: target)
    target.desc == "The gem"
  end

  test "pattern_names is every spelling a build or pattern of the target can take" do
    Expect
    server_target.pattern_names == [
      "cellbound-3d-server", "cellbound-3d-server-dev", "cellbound-3d-server-release",
      "cellbound-3d-server-linux64", "cellbound-3d-server-linux64-dev", "cellbound-3d-server-linux64-release",
    ]
    gem_target.pattern_names == ["rspock"]
  end

  test "desc defaults when omitted" do
    Expect
    Dev::Lifecycle::Target.new(name: "opencell").desc == "(no description)"
  end

  test "a target name may not end in a platform or config id, since that spells a build of a shorter target: #{name}" do
    When
    Dev::Lifecycle::Target.new(name: name)

    Then
    error = raises(Dev::Lifecycle::Target::ReservedTargetSuffixError)
    error.message.include?("'#{name}'")
    error.message.include?("'#{shorter}'")

    Where
    name                      | shorter
    "cellbound-3d-win64"      | "cellbound-3d"
    "cellbound-3d-release"    | "cellbound-3d"
    "snappy-server-linux64"   | "snappy-server"
    "foo-win64-dev"           | "foo-win64"
  end

  test "a single-segment name that is itself an id has no shorter target to shadow, so it is allowed: #{name}" do
    Expect
    Dev::Lifecycle::Target.new(name: name).name == name

    Where
    name
    "dev"
    "release"
    "macos"
  end

  test "a target name is lower-case alphanumeric segments joined by single dashes: #{name.inspect}" do
    When
    Dev::Lifecycle::Target.new(name: name)

    Then
    raises Dev::Lifecycle::Target::InvalidTargetNameError

    Where
    name
    ""
    "Cellbound"
    "cellbound_3d"
    "cellbound--3d"
    "-cellbound"
    "cellbound-"
    "cell bound"
  end

  test "an axis may not list a value twice" do
    When
    Dev::Lifecycle::Target.new(name: "foo", configs: [Dev::Lifecycle::Config::Release, Dev::Lifecycle::Config::Release])

    Then
    error = raises(Dev::Lifecycle::Target::DuplicateAxisValueError)
    error.message.include?("configs lists release more than once")
  end

  test "targets are values: equal by name, desc and axes" do
    Expect
    client_target == client_target
    client_target.hash == client_target.hash
    client_target != steamworks_target
    client_target != Dev::Lifecycle::Target.new(name: "cellbound-3d", desc: "Client", platforms: client_target.platforms)
    { client_target => 1 }.key?(client_target)
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "support/lifecycle_fixtures"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::TargetTest < Minitest::Test
  include LifecycleFixtures

  LINUX = Dev::EnvironmentRef::Image.new(name: "cellbound-3d-linux")
  HOST = Dev::EnvironmentRef::Host.new

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

  test "targets are values: equal by name, desc, axes, builder, packager and environment" do
    Expect
    client_target == client_target
    client_target.hash == client_target.hash
    client_target != steamworks_target
    client_target != Dev::Lifecycle::Target.new(name: "cellbound-3d", desc: "Client", platforms: client_target.platforms)
    client_target != Dev::Lifecycle::Target.new(
      name: "cellbound-3d", desc: "Client", platforms: client_target.platforms, configs: client_target.configs,
      builder: Dev::Lifecycle::BuilderSpec::Script.new(command: "./bin/build"),
    )
    client_target != Dev::Lifecycle::Target.new(
      name: "cellbound-3d", desc: "Client", platforms: client_target.platforms, configs: client_target.configs,
      packager: Dev::Lifecycle::PackagerSpec::None.new,
    )
    client_target != with_environment(client_target, single(LINUX))
    { client_target => 1 }.key?(client_target)
  end

  test "a target declares nothing to compile and dev's archive packager unless it says otherwise" do
    Given
    target = Dev::Lifecycle::Target.new(name: "rspock")

    Expect
    target.builder.nil?
    !target.buildable?
    target.packager == Dev::Lifecycle::PackagerSpec::Archive.new
    target.packageable?
  end

  test "a target with a build: line is buildable; one with packager: none is built, never shipped" do
    Given
    editor = Dev::Lifecycle::Target.new(
      name: "cellbound-3d-editor",
      builder: Dev::Lifecycle::BuilderSpec::Script.new(command: "./bin/build-editor"),
      packager: Dev::Lifecycle::PackagerSpec::None.new,
    )

    Expect
    editor.buildable?
    editor.builder.to_s == "./bin/build-editor"
    !editor.packageable?
    editor.packager.to_s == "none"
  end

  test "a target declaring no environment leaves every build to the project's default, as a command does" do
    Expect
    client_target.environment.nil?
    client_target.environment_for(PLATFORM::Win64).nil?
    gem_target.environment_for(nil).nil?
  end

  test "a single environment is every build's, whatever its platform" do
    Given
    target = with_environment(client_target, single(LINUX))

    Expect
    target.environment_for(PLATFORM::Win64) == LINUX
    target.environment_for(PLATFORM::Linux64) == LINUX
    with_environment(gem_target, single(HOST)).environment_for(nil) == HOST
  end

  test "a per-platform environment answers each declared platform with its own reference" do
    Given "the editor: built in the Linux image on linux64, on the host on macos"
    target = Dev::Lifecycle::Target.new(
      name: "cellbound-3d-editor",
      platforms: [PLATFORM::Linux64, PLATFORM::Macos],
      environment: per_platform(PLATFORM::Linux64 => LINUX, PLATFORM::Macos => HOST),
    )

    Expect
    target.environment_for(PLATFORM::Linux64) == LINUX
    target.environment_for(PLATFORM::Macos) == HOST
  end

  test "a per-platform environment must name exactly the declared platforms: #{fault}" do
    When
    Dev::Lifecycle::Target.new(name: "cellbound-3d", platforms: platforms, environment: per_platform(references))

    Then
    error = raises(Dev::Lifecycle::Target::EnvironmentPlatformsError)
    error.message.include?("target 'cellbound-3d'")
    error.message.include?(says)

    Where
    fault               | platforms                            | references                                            | says
    "an undeclared one" | [PLATFORM::Win64]                    | { PLATFORM::Win64 => LINUX, PLATFORM::Macos => HOST } | "names macos, which the target does not declare"
    "a missing one"     | [PLATFORM::Win64, PLATFORM::Linux64] | { PLATFORM::Win64 => LINUX }                          | "leaves out linux64"
    "both at once"      | [PLATFORM::Win64, PLATFORM::Linux64] | { PLATFORM::Win64 => LINUX, PLATFORM::Macos => HOST } | "names macos, which the target does not declare and leaves out linux64"
    "no platforms"      | []                                   | { PLATFORM::Win64 => LINUX }                          | "declares no platforms, so `environment:` takes one value"
  end

  private

  def single(reference)
    Dev::Lifecycle::TargetEnvironment::Single.new(reference:)
  end

  def per_platform(references)
    Dev::Lifecycle::TargetEnvironment::PerPlatform.new(references:)
  end

  def with_environment(target, environment)
    Dev::Lifecycle::Target.new(
      name: target.name, desc: target.desc, platforms: target.platforms, configs: target.configs, environment:,
    )
  end
end

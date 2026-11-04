# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/environment_ref"
require "dev/lifecycle"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::TargetEnvironmentTest < Minitest::Test
  LINUX = Dev::EnvironmentRef::Image.new(name: "cellbound-3d-linux")
  HOST = Dev::EnvironmentRef::Host.new

  test "a single environment is one reference for every build, spelled as the reference" do
    Given
    environment = Dev::Lifecycle::TargetEnvironment::Single.new(reference: LINUX)

    Expect
    environment.reference == LINUX
    environment.to_s == "cellbound-3d-linux"
    environment == Dev::Lifecycle::TargetEnvironment::Single.new(reference: LINUX)
    environment != Dev::Lifecycle::TargetEnvironment::Single.new(reference: HOST)
    environment.hash == Dev::Lifecycle::TargetEnvironment::Single.new(reference: LINUX).hash
  end

  test "a per-platform environment is one reference per platform, in declaration order" do
    Given
    references = { Dev::Lifecycle::Platform::Linux64 => LINUX, Dev::Lifecycle::Platform::Macos => HOST }
    environment = Dev::Lifecycle::TargetEnvironment::PerPlatform.new(references:)

    Expect
    environment.references == references
    environment.platforms == [Dev::Lifecycle::Platform::Linux64, Dev::Lifecycle::Platform::Macos]
    environment.to_s == "linux64: cellbound-3d-linux, macos: host"
    environment == Dev::Lifecycle::TargetEnvironment::PerPlatform.new(references:)
    environment.hash == Dev::Lifecycle::TargetEnvironment::PerPlatform.new(references:).hash
    environment != Dev::Lifecycle::TargetEnvironment::Single.new(reference: LINUX)
  end

  test "a per-platform environment is a value: the mapping handed in is copied, not held" do
    Given
    references = { Dev::Lifecycle::Platform::Linux64 => LINUX }
    environment = Dev::Lifecycle::TargetEnvironment::PerPlatform.new(references:)

    When "the caller mutates its own mapping"
    references[Dev::Lifecycle::Platform::Macos] = HOST

    Then
    environment.platforms == [Dev::Lifecycle::Platform::Linux64]
    environment.references.frozen?
  end
end

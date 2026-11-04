# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/dependency"
require "dev/environment_image"
require "dev/lifecycle"
require "dev/placement"
require "dev/target_placement"
require "support/lifecycle_fixtures"

transform!(RSpock::AST::Transformation)
class Dev::TargetPlacementTest < Minitest::Test
  include LifecycleFixtures

  test "placement_for answers a build with its platform's placement; config never enters" do
    Given "the client: win64 in the Linux image, linux64 on the host"
    placement = Dev::TargetPlacement.new(
      target: client_target,
      placements: { PLATFORM::Win64 => image_placement, PLATFORM::Linux64 => Dev::Placement::Host.new },
      host_platform: PLATFORM::Linux64,
    )

    Expect
    placement.placement_for(build("cellbound-3d-win64-dev")) == image_placement
    placement.placement_for(build("cellbound-3d-win64-release")) == image_placement
    placement.placement_for(build("cellbound-3d-linux64-dev")) == Dev::Placement::Host.new
  end

  test "a platform-less target's one build is placed under nil and is always buildable here" do
    Given
    placement = Dev::TargetPlacement.new(target: gem_target, placements: { nil => Dev::Placement::Host.new }, host_platform: PLATFORM::Macos)

    Expect
    placement.placement_for(build("rspock")) == Dev::Placement::Host.new
    placement.buildable_here?(build("rspock"))
  end

  test "a build of another target is refused" do
    Given
    placement = Dev::TargetPlacement.new(target: gem_target, placements: { nil => Dev::Placement::Host.new }, host_platform: PLATFORM::Macos)

    When
    placement.placement_for(build("cellbound-3d-server-linux64-dev"))

    Then
    error = raises(Dev::TargetPlacement::ForeignBuildError)
    error.message.include?("is of target 'cellbound-3d-server', not 'rspock'")
  end

  test "buildable here: in an image always, on the host only when the host is the build's platform — host #{host}" do
    Given
    placement = Dev::TargetPlacement.new(
      target: client_target,
      placements: { PLATFORM::Win64 => Dev::Placement::Host.new, PLATFORM::Linux64 => image_placement },
      host_platform: host,
    )

    Expect
    placement.buildable_here?(build("cellbound-3d-win64-dev")) == win64_on_host
    placement.buildable_here?(build("cellbound-3d-linux64-dev"))

    Where
    host             | win64_on_host
    PLATFORM::Win64  | true
    PLATFORM::Macos  | false
  end

  test "assert_buildable_here! refuses a host-placed build of another platform, naming the fix" do
    Given "the editor's macos build, asked for on the Linux box"
    editor = Dev::Lifecycle::Target.new(name: "cellbound-3d-editor", platforms: [PLATFORM::Linux64, PLATFORM::Macos])
    placement = Dev::TargetPlacement.new(
      target: editor,
      placements: { PLATFORM::Linux64 => image_placement, PLATFORM::Macos => Dev::Placement::Host.new },
      host_platform: PLATFORM::Linux64,
    )
    macos_build = Dev::Lifecycle::Build.new(target: editor, platform: PLATFORM::Macos)

    When
    placement.assert_buildable_here!(macos_build)

    Then
    error = raises(Dev::TargetPlacement::HostDoesNotProduceError)
    error.message.include?("`cellbound-3d-editor-macos` builds on the host, and this host is linux64, which does not produce macos")
    error.message.include?("build it on a macos host, or name an image whose `target_platforms` has macos")
  end

  test "target placements are values" do
    Given
    a = Dev::TargetPlacement.new(target: gem_target, placements: { nil => Dev::Placement::Host.new }, host_platform: PLATFORM::Macos)
    b = Dev::TargetPlacement.new(target: gem_target, placements: { nil => Dev::Placement::Host.new }, host_platform: PLATFORM::Macos)
    c = Dev::TargetPlacement.new(target: gem_target, placements: { nil => Dev::Placement::Host.new }, host_platform: PLATFORM::Linux64)

    Expect
    a == b
    a.hash == b.hash
    a != c
    a.placements.frozen?
  end

  private

  def image_placement
    Dev::Placement::Image.new(image: Dev::EnvironmentImage.from_pin(pin))
  end

  def pin
    Dev::Deps::Dependency.new(
      name: "cellbound-3d-linux", integration: :image, group: :app, version: "ue5.8-3", hash: "SHA256=#{"a" * 64}",
      metadata: {
        "from" => "ghcr.io/d3mlabs/unreal-engine-build-base", "platform" => "linux/amd64", "platforms" => ["linux/amd64"],
        "registry" => "ghcr.io/d3mlabs", "apt" => [], "target_platforms" => ["win64", "linux64"],
      },
    )
  end
end

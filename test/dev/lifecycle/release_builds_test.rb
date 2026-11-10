# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "support/lifecycle_fixtures"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::ReleaseBuildsTest < Minitest::Test
  include LifecycleFixtures

  RELEASE_BUILDS = Dev::Lifecycle::ReleaseBuilds

  def unshipped_target
    Dev::Lifecycle::Target.new(name: "opencell", desc: "The sim", packager: Dev::Lifecycle::PackagerSpec::None.new)
  end

  def patterns(*names)
    names.map { |name| Dev::Lifecycle::BuildPattern.parse(name, all_targets + [unshipped_target]) }
  end

  test "declared: each pattern with its config named is spelled out per platform, in declaration order" do
    When
    release = RELEASE_BUILDS.declared(patterns("cellbound-3d-release", "cellbound-3d-steamworks-win64-release", "rspock"))

    Then
    release.names == ["cellbound-3d-win64-release", "cellbound-3d-linux64-release", "cellbound-3d-steamworks-win64-release", "rspock"]
    release == RELEASE_BUILDS.new(builds: release.builds)
  end

  test "declared: a pattern that leaves the config open on a target declaring configs is refused with the configs to name" do
    When
    RELEASE_BUILDS.declared(patterns("cellbound-3d-win64"))

    Then
    error = raises(RELEASE_BUILDS::ConfigNotNamedError)
    error.message.include?("'cellbound-3d-win64' spans dev and release")
    error.message.include?("cellbound-3d-win64-dev, cellbound-3d-win64-release")
  end

  test "declared: a build of a target with packager: none is refused — there is nothing to attach" do
    When
    RELEASE_BUILDS.declared(patterns("rspock", "opencell"))

    Then
    error = raises(RELEASE_BUILDS::NotPackageableError)
    error.message.include?("'opencell'")
    error.message.include?("`packager: none`")
  end

  test "declared: a build named twice — directly or through two overlapping patterns — is refused" do
    When
    RELEASE_BUILDS.declared(patterns("cellbound-3d-release", "cellbound-3d-win64-release"))

    Then
    error = raises(RELEASE_BUILDS::DuplicateBuildError)
    error.message.include?("'cellbound-3d-win64-release' more than once")
  end

  test "default (release: {}) is every build of every packageable target when each has at most one config" do
    When
    release = RELEASE_BUILDS.default([steamworks_target, gem_target, unshipped_target])

    Then "the unshipped target is left out silently: it is invisible to the release"
    release.names == ["cellbound-3d-steamworks-win64-release", "rspock"]
  end

  test "default (release: {}) refuses a packageable target with several configs, naming the targets: list to declare" do
    When
    RELEASE_BUILDS.default(all_targets)

    Then
    error = raises(RELEASE_BUILDS::ConfigNotNamedError)
    error.message.include?("'cellbound-3d', 'cellbound-3d-server' declare several configs")
    error.message.include?("cellbound-3d-dev, cellbound-3d-release, cellbound-3d-server-dev, cellbound-3d-server-release")
  end

  test "default (release: {}) with no packageable target is refused: #{what}" do
    When
    RELEASE_BUILDS.default(targets)

    Then
    raises(RELEASE_BUILDS::NothingToReleaseError)

    Where
    what                        | targets
    "no target at all"          | []
    "only an unshipped target"  | [Dev::Lifecycle::Target.new(name: "opencell", packager: Dev::Lifecycle::PackagerSpec::None.new)]
  end
end

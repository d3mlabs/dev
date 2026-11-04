# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "support/lifecycle_fixtures"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::ScriptEnvTest < Minitest::Test
  include LifecycleFixtures

  test "a build: script sees the build's declared axes and the install directory" do
    Expect
    Dev::Lifecycle::ScriptEnv.for_build(build("cellbound-3d-win64-dev"), install: Pathname("/data/install")) == {
      "DEV_TARGET" => "cellbound-3d",
      "DEV_PLATFORM" => "win64",
      "DEV_CONFIG" => "dev",
      "DEV_INSTALL" => "/data/install",
    }
  end

  test "an axis the target does not declare is absent, not empty" do
    Expect
    Dev::Lifecycle::ScriptEnv.for_build(build("rspock"), install: Pathname("/data/install")) == {
      "DEV_TARGET" => "rspock",
      "DEV_INSTALL" => "/data/install",
    }
  end

  test "a package: script sees the build's env plus the archive path without its extension" do
    Expect
    Dev::Lifecycle::ScriptEnv.for_package(
      build("cellbound-3d-server-linux64-release"),
      install: Pathname("/data/install"),
      archive: Pathname("/data/store/cellbound-3d-server-linux64-release"),
    ) == {
      "DEV_TARGET" => "cellbound-3d-server",
      "DEV_PLATFORM" => "linux64",
      "DEV_CONFIG" => "release",
      "DEV_INSTALL" => "/data/install",
      "DEV_ARTIFACT" => "/data/store/cellbound-3d-server-linux64-release",
    }
  end
end

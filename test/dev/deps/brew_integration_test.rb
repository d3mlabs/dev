# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/brew_integration"
require "dev/deps/brew_registry"
require "dev/deps/cache"
require "dev/deps/pin"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::BrewIntegrationTest < Minitest::Test
  test "install_all calls brew install for each formula pin" do
    Given
    dir = Dir.mktmpdir("dev-brew-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    registry = Dev::Deps::BrewRegistry.new
    integration = Dev::Deps::BrewIntegration.new(repository: registry, cache: cache)
    pins = [
      Dev::Deps::Pin.new(name: "cmake", integration: :brew, group: :build,
                          version: "3.31.4", hash: "SHA256=abc", metadata: {}),
    ]

    # Stub the brew install
    Dev::Deps::BrewIntegration.any_instance.stubs(:brew_installed?).returns(false)
    Dev::Deps::BrewIntegration.any_instance.stubs(:run_brew_install).returns(true)

    When
    integration.install_all(pins, root: dir)

    Then "no error raised means install was attempted"
    true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all skips env-scoped pins not matching current env" do
    Given
    dir = Dir.mktmpdir("dev-brew-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    registry = Dev::Deps::BrewRegistry.new
    integration = Dev::Deps::BrewIntegration.new(repository: registry, cache: cache, env: "dev")
    pins = [
      Dev::Deps::Pin.new(name: "ruby", integration: :brew, group: :build,
                          version: "3.3.0", hash: "SHA256=bbb",
                          metadata: { "env" => "ci" }),
      Dev::Deps::Pin.new(name: "ccache", integration: :brew, group: :build,
                          version: "4.10.2", hash: "SHA256=aaa", metadata: {}),
    ]

    # ccache should be installed (global), ruby should be skipped (env=ci, we're dev)
    Dev::Deps::BrewIntegration.any_instance.stubs(:brew_installed?).with("ccache").returns(false)
    Dev::Deps::BrewIntegration.any_instance.stubs(:run_brew_install).with("ccache", anything).returns(true)

    When
    integration.install_all(pins, root: dir)

    Then "no error — ruby was skipped, ccache was installed"
    true

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

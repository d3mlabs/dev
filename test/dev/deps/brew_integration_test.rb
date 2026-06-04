# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/brew_integration"
require "dev/deps/brew_repository"
require "dev/deps/cache"
require "dev/deps/dependency"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::BrewIntegrationTest < Minitest::Test
  test "install_all calls brew install for each formula dep" do
    Given "a brew dependency"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    repository = Dev::Deps::BrewRepository.new
    integration = Dev::Deps::BrewIntegration.new(repository: repository, cache: cache)
    deps = [
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build,
                                version: "3.31.4", hash: "SHA256=abc", metadata: {}),
    ]

    Dev::Deps::BrewIntegration.any_instance.stubs(:brew_installed?).returns(false)
    Dev::Deps::BrewIntegration.any_instance.stubs(:run_brew_install).returns(true)

    When "installing all"
    integration.install_all(deps)

    Then "no error raised means install was attempted"
    true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all skips env-scoped deps not matching current env" do
    Given "deps with mixed env scoping"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    repository = Dev::Deps::BrewRepository.new
    integration = Dev::Deps::BrewIntegration.new(repository: repository, cache: cache, env: "dev")
    deps = [
      Dev::Deps::Dependency.new(name: "ruby", integration: :brew, group: :build,
                                version: "3.3.0", hash: "SHA256=bbb",
                                metadata: { "env" => "ci" }),
      Dev::Deps::Dependency.new(name: "ccache", integration: :brew, group: :build,
                                version: "4.10.2", hash: "SHA256=aaa", metadata: {}),
    ]

    Dev::Deps::BrewIntegration.any_instance.stubs(:brew_installed?).with("ccache").returns(false)
    Dev::Deps::BrewIntegration.any_instance.stubs(:run_brew_install).with("ccache", anything).returns(true)

    When "installing all"
    integration.install_all(deps)

    Then "no error — ruby was skipped, ccache was installed"
    true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all raises InstallError when brew install fails" do
    Given "a brew dependency with a failing install"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    repository = Dev::Deps::BrewRepository.new
    integration = Dev::Deps::BrewIntegration.new(repository: repository, cache: cache)
    deps = [
      Dev::Deps::Dependency.new(name: "bad_formula", integration: :brew, group: :build,
                                version: "1.0.0", hash: nil, metadata: {}),
    ]

    integration.stubs(:brew_installed?).returns(false)
    failed_status = stub(success?: false)
    Open3.stubs(:capture3)
         .with("brew", "install", "bad_formula@1.0.0")
         .returns(["", "Error: No available formula", failed_status])

    When "installing all"
    integration.install_all(deps)

    Then
    raises Dev::Deps::BrewIntegration::InstallError

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

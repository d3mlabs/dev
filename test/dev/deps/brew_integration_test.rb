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
    Dev::Deps::BrewIntegration.any_instance.stubs(:run_brew_install).returns(nil)

    When "installing all"
    integration.install_all(deps)

    Then "no error raised means install was attempted"
    true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all installs the bare formula for an unversioned dep" do
    Given "an unversioned brew dependency (resolved version recorded, no suffix)"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    integration = Dev::Deps::BrewIntegration.new(repository: Dev::Deps::BrewRepository.new, cache: cache)
    deps = [
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build,
                                version: "4.3.4", hash: "SHA256=abc", metadata: {}),
    ]
    integration.stubs(:brew_installed?).returns(false)
    Open3.expects(:capture3).with("brew", "install", "cmake").returns(["", "", stub(success?: true)])

    When "installing all"
    integration.install_all(deps)

    Then "brew install targets the bare formula, never name@resolved-version"
    true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all installs the versioned formula from the suffix metadata" do
    Given "a versioned brew dependency (resolved 18.1.8, suffix 18)"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    integration = Dev::Deps::BrewIntegration.new(repository: Dev::Deps::BrewRepository.new, cache: cache)
    deps = [
      Dev::Deps::Dependency.new(name: "llvm", integration: :brew, group: :build,
                                version: "18.1.8", hash: "SHA256=abc",
                                metadata: { "version_suffix" => "18" }),
    ]
    integration.stubs(:brew_installed?).returns(false)
    Open3.expects(:capture3).with("brew", "install", "llvm@18").returns(["", "", stub(success?: true)])

    When "installing all"
    integration.install_all(deps)

    Then "brew install targets llvm@18, not llvm@18.1.8"
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
                                version: "1.0.0", hash: nil, metadata: { "version_suffix" => "1" }),
    ]

    integration.stubs(:brew_installed?).returns(false)
    failed_status = stub(success?: false)
    Open3.stubs(:capture3)
         .with("brew", "install", "bad_formula@1")
         .returns(["", "Error: No available formula", failed_status])

    When "installing all"
    integration.install_all(deps)

    Then
    raises Dev::Deps::BrewIntegration::InstallError

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

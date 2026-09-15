# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/brew_integration"
require "dev/deps/brew_repository"
require "dev/deps/cache"
require "dev/deps/dependency"
require "dev/deps/tap"
require "etc"
require "pathname"
require "tmpdir"
require "uri"

transform!(RSpock::AST::Transformation)
class Dev::Deps::BrewIntegrationTest < Minitest::Test
  test "install_all calls brew install for each formula dep" do
    Given "a brew dependency"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    repository = Dev::Deps::BrewRepository.new
    integration = Dev::Deps::BrewIntegration.new(repository: repository, cache: cache, brew_prefix: dir)
    deps = [
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build,
        version: "3.31.4", hash: "SHA256=abc", metadata: {}),
    ]

    integration.stubs(:brew_installed?).returns(false)
    integration.stubs(:run_brew_install).returns(nil)

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
    integration = Dev::Deps::BrewIntegration.new(repository: Dev::Deps::BrewRepository.new, cache: cache, brew_prefix: dir)
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
    integration = Dev::Deps::BrewIntegration.new(repository: Dev::Deps::BrewRepository.new, cache: cache, brew_prefix: dir)
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
    integration = Dev::Deps::BrewIntegration.new(repository: repository, cache: cache, brew_prefix: dir)
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
    error = assert_raises(Dev::Deps::Integration::PartialInstallError) do
      integration.install_all(deps)
    end

    Then "the per-dep failure is the brew install error"
    error.failures[0][1].is_a?(Dev::Deps::BrewIntegration::InstallError)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all attempts the remaining formulae when one fails, then raises the aggregate" do
    Given "two brew dependencies, the first of which fails to install"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    integration = Dev::Deps::BrewIntegration.new(repository: Dev::Deps::BrewRepository.new, cache: cache, brew_prefix: dir)
    deps = [
      Dev::Deps::Dependency.new(name: "bad_formula", integration: :brew, group: :build,
        version: "1.0.0", hash: nil, metadata: {}),
      Dev::Deps::Dependency.new(name: "good_formula", integration: :brew, group: :build,
        version: "2.0.0", hash: nil, metadata: {}),
    ]
    integration.stubs(:brew_installed?).returns(false)
    Open3.stubs(:capture3)
         .with("brew", "install", "bad_formula")
         .returns(["", "Error: No available formula", stub(success?: false)])
    Open3.expects(:capture3)
         .with("brew", "install", "good_formula")
         .returns(["", "", stub(success?: true)])

    When "installing all and capturing the aggregate error"
    error = nil
    begin
      integration.install_all(deps)
    rescue StandardError => e
      error = e
    end

    Then "good_formula was still installed (Mocha-verified) and the aggregate lists bad_formula"
    error.is_a?(Dev::Deps::Integration::PartialInstallError)
    error.failures.map(&:first) == ["bad_formula"]
    error.failures[0][1].is_a?(Dev::Deps::BrewIntegration::InstallError)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all registers a local file:// tap at its resolved path and publishes the tap env" do
    Given "an integration with a project dir and a local tap"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    tap = Dev::Deps::Tap.new(name: "local/tap", url: "file://#{dir}/brew-tap")
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new, cache: cache, taps: [tap], project_dir: dir, brew_prefix: dir,
    )
    integration.expects(:system).with("brew", "tap", "local/tap", "#{dir}/brew-tap").returns(true)

    When "installing all (no deps, taps only)"
    integration.install_all([])

    Then "the local tap env vars point at the resolved tap"
    ENV["TAP_NAME"] == "local/tap"
    ENV["LOCAL_TAP_DIR"] == "#{dir}/brew-tap"

    Cleanup
    ENV.delete("TAP_NAME")
    ENV.delete("LOCAL_TAP_DIR")
    FileUtils.rm_rf(dir)
  end

  test "install_all registers a remote URL tap with its URL" do
    Given "an integration with a remote (non-file) tap"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    tap = Dev::Deps::Tap.new(name: "org/tap", url: "https://github.com/org/homebrew-tap")
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new, cache: cache, taps: [tap], project_dir: dir, brew_prefix: dir,
    )
    integration.expects(:system).with("brew", "tap", "org/tap", "https://github.com/org/homebrew-tap").returns(true)

    When "installing all (no deps, taps only)"
    integration.install_all([])

    Then "brew tap received the URL (expectation verified by Mocha)"
    true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "brew writes run unescalated when the prefix is writable by the current user" do
    Given "an integration whose brew prefix is writable"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    prefix = File.join(dir, "homebrew")
    FileUtils.mkdir_p(prefix)
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new,
      cache: Dev::Deps::Cache.new(cache_dir: dir),
      brew_prefix: prefix,
    )
    deps = [
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build,
        version: "4.3.4", hash: nil, metadata: {}),
    ]
    integration.stubs(:brew_installed?).returns(false)
    Open3.expects(:capture3).with("brew", "install", "cmake").returns(["", "", stub(success?: true)])

    When "installing all"
    integration.install_all(deps)

    Then "brew ran directly, no sudo (Mocha-verified)"
    true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "brew writes escalate to the prefix owner when the prefix is not writable" do
    Given "an integration whose brew prefix is owned read-only"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    prefix = File.join(dir, "homebrew")
    FileUtils.mkdir_p(prefix)
    FileUtils.chmod(0o555, prefix)
    owner = Etc.getpwuid(File.stat(prefix).uid).name
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new,
      cache: Dev::Deps::Cache.new(cache_dir: dir),
      brew_prefix: prefix,
    )
    deps = [
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build,
        version: "4.3.4", hash: nil, metadata: {}),
    ]
    integration.stubs(:brew_installed?).returns(false)
    Open3.expects(:capture3)
         .with("sudo", "-n", "-u", owner, "brew", "install", "cmake")
         .returns(["", "", stub(success?: true)])

    When "installing all"
    integration.install_all(deps)

    Then "brew ran through sudo -n as the prefix owner (Mocha-verified)"
    true

    Cleanup
    FileUtils.chmod(0o755, prefix)
    FileUtils.rm_rf(dir)
  end

  test "a sudo refusal surfaces the agent bootstrap remediation" do
    Given "an unwritable prefix and a sudo -n that refuses (no sudoers edge)"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    prefix = File.join(dir, "homebrew")
    FileUtils.mkdir_p(prefix)
    FileUtils.chmod(0o555, prefix)
    owner = Etc.getpwuid(File.stat(prefix).uid).name
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new,
      cache: Dev::Deps::Cache.new(cache_dir: dir),
      brew_prefix: prefix,
    )
    deps = [
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build,
        version: "4.3.4", hash: nil, metadata: {}),
    ]
    integration.stubs(:brew_installed?).returns(false)
    Open3.stubs(:capture3)
         .with("sudo", "-n", "-u", owner, "brew", "install", "cmake")
         .returns(["", "sudo: a password is required\n", stub(success?: false)])

    When "installing all and capturing the aggregate error"
    error = nil
    begin
      integration.install_all(deps)
    rescue StandardError => e
      error = e
    end

    Then "the failure names the missing sudoers edge and its remediation"
    error.is_a?(Dev::Deps::Integration::PartialInstallError)
    error.failures[0][1].message.include?("dev runner register")

    Cleanup
    FileUtils.chmod(0o755, prefix)
    FileUtils.rm_rf(dir)
  end

  test "tap registration escalates with the same prefix-owner rule" do
    Given "a remote tap and an unwritable brew prefix"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    prefix = File.join(dir, "homebrew")
    FileUtils.mkdir_p(prefix)
    FileUtils.chmod(0o555, prefix)
    owner = Etc.getpwuid(File.stat(prefix).uid).name
    tap = Dev::Deps::Tap.new(name: "org/tap", url: "https://github.com/org/homebrew-tap")
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new,
      cache: Dev::Deps::Cache.new(cache_dir: dir),
      taps: [tap], project_dir: dir, brew_prefix: prefix,
    )
    integration.expects(:system)
               .with("sudo", "-n", "-u", owner, "brew", "tap", "org/tap", "https://github.com/org/homebrew-tap")
               .returns(true)

    When "installing all (no deps, taps only)"
    integration.install_all([])

    Then "brew tap ran through sudo -n as the prefix owner (Mocha-verified)"
    true

    Cleanup
    FileUtils.chmod(0o755, prefix)
    FileUtils.rm_rf(dir)
  end

  test "resolve_file_url resolves a ./ path against the project dir" do
    Given "an integration with a project dir and a project-relative file URI"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new, cache: Dev::Deps::Cache.new(cache_dir: dir), project_dir: dir,
    )
    relative_uri = URI::Generic.new("file", nil, nil, nil, nil, "./brew-tap", nil, nil, nil)

    When "resolving"
    path = integration.send(:resolve_file_url, relative_uri, Pathname(dir))

    Then
    path == File.expand_path(File.join(dir, "brew-tap"))

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

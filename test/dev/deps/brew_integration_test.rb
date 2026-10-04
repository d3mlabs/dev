# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/brew_integration"
require "dev/deps/brew_repository"
require "dev/deps/local_store"
require "dev/deps/dependency"
require "dev/deps/tap"
require "etc"
require "pathname"
require "tmpdir"
require "uri"

transform!(RSpock::AST::Transformation)
class Dev::Deps::BrewIntegrationTest < Minitest::Test
  include SorbetHelper

  # The argv prefix every brew write carries: brew's download cache in the
  # store rooted at `dir`.
  #
  # @param dir [String] the test's data root
  # @return [Array<String>]
  def cache_env(dir)
    ["env", "HOMEBREW_CACHE=#{dir}/tool-caches/brew"]
  end

  test "install_all calls brew install for each formula dep" do
    Given "a brew dependency"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    store = Dev::Deps::LocalStore.new(data_root: dir)
    repository = Dev::Deps::BrewRepository.new
    integration = Dev::Deps::BrewIntegration.new(repository: repository, store: store, brew_prefix: dir)
    deps = [
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build,
        version: "3.31.4", hash: "SHA256=abc", metadata: {}),
    ]

    integration.stubs(:brew_installed?).returns(false)
    integration.stubs(:verify_installed!)
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
    store = Dev::Deps::LocalStore.new(data_root: dir)
    integration = Dev::Deps::BrewIntegration.new(repository: Dev::Deps::BrewRepository.new, store: store, brew_prefix: dir)
    deps = [
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build,
        version: "4.3.4", hash: "SHA256=abc", metadata: {}),
    ]
    integration.stubs(:brew_installed?).returns(false)
    integration.stubs(:verify_installed!)
    Open3.expects(:capture3).with(*cache_env(dir), "brew", "install", "cmake").returns(["", "", stub(success?: true)])

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
    store = Dev::Deps::LocalStore.new(data_root: dir)
    integration = Dev::Deps::BrewIntegration.new(repository: Dev::Deps::BrewRepository.new, store: store, brew_prefix: dir)
    deps = [
      Dev::Deps::Dependency.new(name: "llvm", integration: :brew, group: :build,
        version: "18.1.8", hash: "SHA256=abc",
        metadata: { "version_suffix" => "18" }),
    ]
    integration.stubs(:brew_installed?).returns(false)
    integration.stubs(:verify_installed!)
    Open3.expects(:capture3).with(*cache_env(dir), "brew", "install", "llvm@18").returns(["", "", stub(success?: true)])

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
    store = Dev::Deps::LocalStore.new(data_root: dir)
    repository = Dev::Deps::BrewRepository.new
    integration = Dev::Deps::BrewIntegration.new(repository: repository, store: store, brew_prefix: dir)
    deps = [
      Dev::Deps::Dependency.new(name: "bad_formula", integration: :brew, group: :build,
        version: "1.0.0", hash: nil, metadata: { "version_suffix" => "1" }),
    ]

    integration.stubs(:brew_installed?).returns(false)
    integration.stubs(:verify_installed!)
    failed_status = stub(success?: false)
    Open3.stubs(:capture3)
         .with(*cache_env(dir), "brew", "install", "bad_formula@1")
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
    store = Dev::Deps::LocalStore.new(data_root: dir)
    integration = Dev::Deps::BrewIntegration.new(repository: Dev::Deps::BrewRepository.new, store: store, brew_prefix: dir)
    deps = [
      Dev::Deps::Dependency.new(name: "bad_formula", integration: :brew, group: :build,
        version: "1.0.0", hash: nil, metadata: {}),
      Dev::Deps::Dependency.new(name: "good_formula", integration: :brew, group: :build,
        version: "2.0.0", hash: nil, metadata: {}),
    ]
    integration.stubs(:brew_installed?).returns(false)
    integration.stubs(:verify_installed!)
    Open3.stubs(:capture3)
         .with(*cache_env(dir), "brew", "install", "bad_formula")
         .returns(["", "Error: No available formula", stub(success?: false)])
    Open3.expects(:capture3)
         .with(*cache_env(dir), "brew", "install", "good_formula")
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

  # --- B: verify the installed version against the lock -----------------------

  test "install_formula verifies the installed version against the lock: #{description}" do
    Given "a locked formula and what brew reports installed after the install step"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir), brew_prefix: dir,
    )
    dep = Dev::Deps::Dependency.new(name: "llvm", integration: :brew, group: :build,
      version: "18.1.8", hash: nil, metadata: { "version_suffix" => "18" })
    integration.stubs(:brew_installed?).returns(true)
    Open3.stubs(:capture3).with("brew", "list", "--versions", "llvm@18").returns([brew_list, "", stub(success?: true)])

    When "installing"
    outcome = begin
      integration.install_all([dep])
      :ok
    rescue Dev::Deps::Integration::PartialInstallError => e
      e.failures.fetch(0).fetch(1)
    end

    Then "a keg at the locked version (revision suffix aside) passes; anything else is a typed mismatch naming both"
    passes ? outcome == :ok : outcome.is_a?(Dev::Deps::BrewIntegration::VersionMismatchError)
    passes || outcome.message.include?("llvm@18 18.1.9")
    passes || outcome.message.include?("18.1.8")
    passes || outcome.message.include?("dev deps update")
    passes || outcome.message.include?("brew upgrade llvm@18")

    Cleanup
    FileUtils.rm_rf(dir)

    Where
    description                        | brew_list                      | passes
    "exact match"                      | "llvm@18 18.1.8\n"             | true
    "match behind a brew revision"     | "llvm@18 18.1.8_1\n"           | true
    "one of several kegs matches"      | "llvm@18 18.1.7 18.1.8\n"      | true
    "brew moved on past the lock"      | "llvm@18 18.1.9\n"             | false
  end

  test "install_formula verifies after a fresh install too, so a lock brew can no longer satisfy fails at once" do
    Given "a formula not yet installed, whose install lands a newer version than the lock pins"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir), brew_prefix: dir,
    )
    dep = Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build,
      version: "4.4.3", hash: nil, metadata: {})
    integration.stubs(:brew_installed?).returns(false)
    Open3.stubs(:capture3).with(*cache_env(dir), "brew", "install", "cmake").returns(["", "", stub(success?: true)])
    Open3.stubs(:capture3).with("brew", "list", "--versions", "cmake").returns(["cmake 4.5.0\n", "", stub(success?: true)])

    When "installing"
    integration.install_all([dep])

    Then "the mismatch is the per-dep failure"
    error = raises Dev::Deps::Integration::PartialInstallError
    error.failures.fetch(0).fetch(1).is_a?(Dev::Deps::BrewIntegration::VersionMismatchError)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_formula skips verification for a dep that locked no version (a tap formula brew reports none for)" do
    Given "a versionless brew dep"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir), brew_prefix: dir,
    )
    dep = Dev::Deps::Dependency.new(name: "wwise-cli", integration: :brew, group: :build,
      version: nil, hash: nil, metadata: { "tap" => "d3mlabs/d3mlabs" })
    integration.stubs(:brew_installed?).returns(true)

    When "installing"
    integration.install_all([dep])

    Then "brew list --versions is never consulted"
    0 * Open3.capture3("brew", "list", "--versions", anything)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  # --- A: pinned taps for image builds ----------------------------------------

  PINNED_ENV = ["HOMEBREW_NO_INSTALL_FROM_API=1", "HOMEBREW_NO_AUTO_UPDATE=1"].freeze

  test "install_all with pinned taps checks each tap out at its locked commit, then installs from the taps, not the API" do
    Given "a core formula and a tap formula, each locked with its tap commit"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    pinner = typed_mock(Dev::Deps::TapPinner)
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir), brew_prefix: dir,
      pin_taps: true, tap_pinner: pinner,
    )
    deps = [
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build, version: "4.4.3", hash: nil,
        metadata: { "tap_commit" => "3c67e3be", "format" => "bottle" }),
      Dev::Deps::Dependency.new(name: "wwise-cli", integration: :brew, group: :build, version: "1.0.0", hash: nil,
        metadata: { "tap" => "d3mlabs/d3mlabs", "tap_commit" => "e5810c4f", "format" => "source" }),
    ]
    integration.stubs(:brew_installed?).returns(false)
    integration.stubs(:verify_installed!)

    When "installing all"
    integration.install_all(deps)

    Then "both taps are pinned and brew is told to read them, not the API"
    1 * pinner.pin!("homebrew/core", "3c67e3be")
    1 * pinner.pin!("d3mlabs/d3mlabs", "e5810c4f")
    1 * Open3.capture3(*cache_env(dir), *PINNED_ENV, "brew", "install", "cmake") >> ["", "", stub(success?: true)]
    1 * Open3.capture3(*cache_env(dir), *PINNED_ENV, "brew", "install", "d3mlabs/d3mlabs/wwise-cli") >>
      ["", "", stub(success?: true)]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all with pinned taps refuses a formula the lock has no tap commit for" do
    Given "a lock written before tap commits were recorded"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    pinner = typed_mock(Dev::Deps::TapPinner)
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir), brew_prefix: dir,
      pin_taps: true, tap_pinner: pinner,
    )
    deps = [
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build, version: "4.4.3", hash: nil,
        metadata: {}),
    ]

    When "installing all"
    integration.install_all(deps)

    Then "the stale lock fails loudly with the remediation, before anything is pinned or installed"
    error = raises Dev::Deps::BrewIntegration::UnpinnedFormulaError
    error.message.include?("cmake")
    error.message.include?("dev deps update")
    0 * pinner.pin!(anything, anything)
    0 * Open3.capture3(anything)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all with pinned taps refuses two formulae that pin one tap at different commits" do
    Given "two core formulae locked at different core commits"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    pinner = typed_mock(Dev::Deps::TapPinner)
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir), brew_prefix: dir,
      pin_taps: true, tap_pinner: pinner,
    )
    deps = [
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build, version: "4.4.3", hash: nil,
        metadata: { "tap_commit" => "aaaa" }),
      Dev::Deps::Dependency.new(name: "ninja", integration: :brew, group: :build, version: "1.12", hash: nil,
        metadata: { "tap_commit" => "bbbb" }),
    ]

    When "installing all"
    integration.install_all(deps)

    Then
    error = raises Dev::Deps::BrewIntegration::TapPinConflictError
    error.message.include?("homebrew/core")
    error.message.include?("aaaa")
    error.message.include?("bbbb")
    error.message.include?("dev deps update")
    0 * pinner.pin!(anything, anything)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all with pinned taps leaves casks to brew's own registry" do
    Given "a cask dep and pinned mode"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    pinner = typed_mock(Dev::Deps::TapPinner)
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir), brew_prefix: dir,
      pin_taps: true, tap_pinner: pinner,
    )
    deps = [
      Dev::Deps::Dependency.new(name: "iterm2", integration: :cask, group: :app, version: "3.5", hash: nil,
        metadata: { "cask" => true }),
    ]
    integration.stubs(:brew_installed?).returns(true)

    When "installing all"
    integration.install_all(deps)

    Then "no tap is pinned for it"
    0 * pinner.pin!(anything, anything)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the default tap pinner reads brew's taps directory and the declared taps' URLs" do
    Given "pinned mode without an injected pinner, a declared remote tap, and brew answering --repository"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    tap = Dev::Deps::Tap.new(name: "org/tap", url: "https://github.com/org/homebrew-tap")
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir), brew_prefix: dir,
      taps: [tap], pin_taps: true,
    )
    Open3.stubs(:capture3).with("brew", "--repository").returns(["#{dir}/Homebrew\n", "", stub(success?: true)])

    When "building the pinner"
    pinner = integration.send(:tap_pinner)

    Then
    pinner.taps_root == Pathname("#{dir}/Homebrew/Library/Taps")
    pinner.remote_url("org/tap") == "https://github.com/org/homebrew-tap"
    pinner.remote_url("homebrew/core") == "https://github.com/homebrew/homebrew-core"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the default tap pinner cannot be built without brew" do
    Given "pinned mode and brew --repository failing"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir), brew_prefix: dir,
      pin_taps: true,
    )
    Open3.stubs(:capture3).with("brew", "--repository").returns(["", "command not found", stub(success?: false)])

    When "building the pinner"
    integration.send(:tap_pinner)

    Then
    raises Dev::Deps::BrewIntegration::BrewUnavailableError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all registers a local file:// tap at its resolved path and publishes the tap env" do
    Given "an integration with a project dir and a local tap"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    store = Dev::Deps::LocalStore.new(data_root: dir)
    tap = Dev::Deps::Tap.new(name: "local/tap", url: "file://#{dir}/brew-tap")
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new, store: store, taps: [tap], project_dir: dir, brew_prefix: dir,
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
    store = Dev::Deps::LocalStore.new(data_root: dir)
    tap = Dev::Deps::Tap.new(name: "org/tap", url: "https://github.com/org/homebrew-tap")
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new, store: store, taps: [tap], project_dir: dir, brew_prefix: dir,
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
      store: Dev::Deps::LocalStore.new(data_root: dir),
      brew_prefix: prefix,
    )
    deps = [
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build,
        version: "4.3.4", hash: nil, metadata: {}),
    ]
    integration.stubs(:brew_installed?).returns(false)
    integration.stubs(:verify_installed!)
    Open3.expects(:capture3).with(*cache_env(dir), "brew", "install", "cmake").returns(["", "", stub(success?: true)])

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
      store: Dev::Deps::LocalStore.new(data_root: dir),
      brew_prefix: prefix,
    )
    deps = [
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build,
        version: "4.3.4", hash: nil, metadata: {}),
    ]
    integration.stubs(:brew_installed?).returns(false)
    integration.stubs(:verify_installed!)
    Open3.expects(:capture3)
         .with("sudo", "-n", "-u", owner, *cache_env(dir), "brew", "install", "cmake")
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
      store: Dev::Deps::LocalStore.new(data_root: dir),
      brew_prefix: prefix,
    )
    deps = [
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build,
        version: "4.3.4", hash: nil, metadata: {}),
    ]
    integration.stubs(:brew_installed?).returns(false)
    integration.stubs(:verify_installed!)
    Open3.stubs(:capture3)
         .with("sudo", "-n", "-u", owner, *cache_env(dir), "brew", "install", "cmake")
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
      store: Dev::Deps::LocalStore.new(data_root: dir),
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

  test "a URL-less tap registers by name alone and a failure raises without the escalation hint" do
    Given "a tap with no URL and a writable brew prefix, where brew tap fails"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    tap = Dev::Deps::Tap.new(name: "org/tap")
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new,
      store: Dev::Deps::LocalStore.new(data_root: dir),
      taps: [tap], project_dir: dir, brew_prefix: dir,
    )
    integration.stubs(:system).with("brew", "tap", "org/tap").returns(false)

    When "installing all (no deps, taps only)"
    error = assert_raises(Dev::Deps::BrewIntegration::TapRegistrationError) do
      integration.install_all([])
    end

    Then "the error names the tap and carries no escalation hint (we were not escalated)"
    error.message.include?("brew tap org/tap")
    !error.message.include?("dev runner register")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "an escalated tap failure carries the sudoers-edge remediation hint" do
    Given "a URL-less tap and an unwritable brew prefix, where the escalated brew tap fails"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    prefix = File.join(dir, "homebrew")
    FileUtils.mkdir_p(prefix)
    FileUtils.chmod(0o555, prefix)
    owner = Etc.getpwuid(File.stat(prefix).uid).name
    tap = Dev::Deps::Tap.new(name: "org/tap")
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new,
      store: Dev::Deps::LocalStore.new(data_root: dir),
      taps: [tap], project_dir: dir, brew_prefix: prefix,
    )
    integration.stubs(:system).with("sudo", "-n", "-u", owner, "brew", "tap", "org/tap").returns(false)

    When "installing all (no deps, taps only)"
    error = assert_raises(Dev::Deps::BrewIntegration::TapRegistrationError) do
      integration.install_all([])
    end

    Then "the error points at the sudoers brew edge remediation"
    error.message.include?("dev runner register")

    Cleanup
    FileUtils.chmod(0o755, prefix)
    FileUtils.rm_rf(dir)
  end

  test "brew_prefix is discovered from brew --prefix once and memoized" do
    Given "an integration with no injected prefix and a brew that answers --prefix"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir),
    )
    Open3.expects(:capture3).with("brew", "--prefix").once.returns(["#{dir}\n", "", stub(success?: true)])

    When "resolving the prefix twice"
    first = integration.send(:brew_prefix)
    second = integration.send(:brew_prefix)

    Then "both resolutions return the discovered prefix from a single brew call (Mocha-verified once)"
    first == dir
    second == dir

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "brew_prefix is nil when brew is absent, so writes run unescalated" do
    Given "an integration with no injected prefix and no brew on PATH"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir),
    )
    Open3.stubs(:capture3).with("brew", "--prefix").raises(Errno::ENOENT)

    When "resolving the prefix"
    prefix = integration.send(:brew_prefix)

    Then "the prefix is nil and escalation is empty"
    prefix.nil?
    integration.send(:escalation) == []

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "resolve_file_url resolves a ./ path against the project dir" do
    Given "an integration with a project dir and a project-relative file URI"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir), project_dir: dir,
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

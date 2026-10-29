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
    integration.stubs(:converge!)
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
    passes || !outcome.message.include?("brew upgrade")

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
    integration.stubs(:converge!)
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

  # --- Converging a keg at another version to the lock (dev#350, dev#356) ----

  COMMIT = "3c67e3be0b6a8c7e2d5e2f5d3f8b1f2a5a4b0c0d"

  # A cmake pin at `locked`, from `tap` at COMMIT (homebrew/core when nil).
  #
  # @param locked [String]
  # @param tap [String, nil]
  # @return [Dev::Deps::Dependency]
  def cmake_pin(locked, tap: nil)
    metadata = { "format" => "bottle", "tap_commit" => COMMIT }
    metadata["tap"] = tap if tap
    Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build, version: locked, hash: nil, metadata:)
  end

  # A pin written before the lock recorded tap commits.
  #
  # @param locked [String]
  # @return [Dev::Deps::Dependency]
  def legacy_cmake_pin(locked)
    Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build, version: locked, hash: nil, metadata: {})
  end

  # What `brew list --versions cmake` answers on successive calls.
  #
  # @param versions [Array<String>] one listing per call; the last repeats
  # @return [void]
  def brew_lists_cmake(*versions)
    expectation = Open3.stubs(:capture3).with("brew", "list", "--versions", "cmake")
    versions.each { |listing| expectation = expectation.returns(["cmake #{listing}\n", "", stub(success?: true)]).then }
  end

  # An integration over a fake pinner, with brew refusing any argv that
  # names a file: the install path is a formula spec from a pinned tap,
  # never a bottle on disk (Homebrew installs none, dev#356).
  #
  # @param dir [String] the data root
  # @param pinner [Mocha::Mock]
  # @return [Dev::Deps::BrewIntegration]
  def converging_integration(dir, pinner)
    Open3.expects(:capture3).with { |*args| args.any? { |arg| arg.to_s.end_with?(".tar.gz") } }.never
    Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir), brew_prefix: dir,
      tap_pinner: pinner,
    )
  end

  test "a keg at another version is converged through its tap at the lock's commit: #{description}" do
    Given "cmake 4.4.4 installed, the lock pinning 4.4.5 from a tap commit"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    pinner = typed_mock(Dev::Deps::TapPinner)
    integration = converging_integration(dir, pinner)
    integration.stubs(:brew_installed?).returns(true)
    brew_lists_cmake("4.4.4", "4.4.4 4.4.5")

    When "installing"
    out, _err = capture_io { integration.install_all([cmake_pin("4.4.5", tap:)]) }

    Then "the tap is pinned, brew installs the spec from it and not from the API, the tap is restored; nothing is downloaded by dev"
    1 * pinner.pin!(pinned_tap, COMMIT)
    1 * Open3.capture3(*cache_env(dir), *PINNED_ENV, "brew", "install", spec) >> ["", "", stub(success?: true)]
    1 * pinner.restore!(pinned_tap)
    0 * Open3.capture3(*cache_env(dir), "brew", "update")
    0 * Open3.capture3("curl", any_parameters)
    out.include?("converging")

    Cleanup
    FileUtils.rm_rf(dir)

    Where
    description      | tap                | pinned_tap         | spec
    "a core formula" | nil                | "homebrew/core"    | "cmake"
    "a tap formula"  | "d3mlabs/d3mlabs"  | "d3mlabs/d3mlabs"  | "d3mlabs/d3mlabs/cmake"
  end

  test "a locked version older than the linked keg: brew's refusal is answered with --force --skip-link" do
    Given "cmake 4.4.6 installed and linked, the lock pinning 4.4.5, and brew refusing the plain install"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    pinner = typed_mock(Dev::Deps::TapPinner)
    pinner.stubs(:pin!)
    pinner.stubs(:restore!)
    integration = converging_integration(dir, pinner)
    integration.stubs(:brew_installed?).returns(true)
    brew_lists_cmake("4.4.6", "4.4.5 4.4.6")
    refusal = "Error: cmake 4.4.6 is already installed\nTo install 4.4.5, first run:\n  brew unlink cmake\n"
    Open3.stubs(:capture3).with(*cache_env(dir), *PINNED_ENV, "brew", "install", "cmake").returns(["", refusal, stub(success?: false)])

    When "installing"
    capture_io { integration.install_all([cmake_pin("4.4.5")]) }

    Then "the second install skips brew's link and keg-only checks — the project activates the keg by path, the link stays the user's"
    1 * Open3.capture3(*cache_env(dir), *PINNED_ENV, "brew", "install", "--force", "--skip-link", "cmake") >> ["", "", stub(success?: true)]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the tap is restored when brew refuses both installs, and the failure is the mismatch with brew's words" do
    Given "a pinned formula today's brew will not read (an old commit's DSL)"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    pinner = typed_mock(Dev::Deps::TapPinner)
    pinner.stubs(:pin!)
    integration = converging_integration(dir, pinner)
    integration.stubs(:brew_installed?).returns(true)
    brew_lists_cmake("4.4.6")
    dsl = "Error: homebrew/core/cmake: 'because' argument should use valid symbol or a string!\n"
    Open3.stubs(:capture3).with { |*args| args.include?("install") }.returns(["", dsl, stub(success?: false)])

    When "installing"
    capture_io { integration.install_all([cmake_pin("4.4.5")]) }

    Then "restored regardless; the mismatch names what brew has, what the lock pins, brew's reason, and the re-lock"
    1 * pinner.restore!("homebrew/core")
    error = raises Dev::Deps::Integration::PartialInstallError
    failure = error.failures.fetch(0).fetch(1)
    failure.is_a?(Dev::Deps::BrewIntegration::VersionMismatchError)
    failure.message.include?("cmake 4.4.6")
    failure.message.include?("4.4.5")
    failure.message.include?("'because' argument")
    failure.message.include?("dev deps update")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a tap that cannot be pinned is the per-dep failure, in git's words" do
    Given "a remote without the commit"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    pinner = typed_mock(Dev::Deps::TapPinner)
    pinner.stubs(:pin!).raises(Dev::Deps::TapPinner::PinError.new(tap: "homebrew/core", commit: COMMIT, step: "fetch", stderr: "fatal: remote error"))
    integration = converging_integration(dir, pinner)
    integration.stubs(:brew_installed?).returns(true)
    brew_lists_cmake("4.4.4")

    When "installing"
    capture_io { integration.install_all([cmake_pin("4.4.5")]) }

    Then
    error = raises Dev::Deps::Integration::PartialInstallError
    failure = error.failures.fetch(0).fetch(1)
    failure.is_a?(Dev::Deps::TapPinner::PinError)
    failure.message.include?("fatal: remote error")
    0 * Open3.capture3(*cache_env(dir), *PINNED_ENV, "brew", "install", any_parameters)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a pin written before the lock recorded tap commits converges by a refreshed index and brew upgrade" do
    Given "a keg behind a legacy lock"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    pinner = typed_mock(Dev::Deps::TapPinner)
    integration = converging_integration(dir, pinner)
    integration.stubs(:brew_installed?).returns(true)
    brew_lists_cmake("4.4.4", "4.4.5")

    When "installing"
    capture_io { integration.install_all([legacy_cmake_pin("4.4.5")]) }

    Then "the index is refreshed (a checkpoint's is as old as the checkpoint), then brew upgrades the formula; no tap is touched"
    1 * Open3.capture3(*cache_env(dir), "brew", "update") >> ["", "", stub(success?: true)]
    1 * Open3.capture3(*cache_env(dir), "brew", "upgrade", "cmake") >> ["", "", stub(success?: true)]
    0 * pinner.pin!(any_parameters)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a failed brew update is a warning; the upgrade still runs against the index brew has" do
    Given "an offline brew update"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    integration = converging_integration(dir, typed_mock(Dev::Deps::TapPinner))
    integration.stubs(:brew_installed?).returns(true)
    brew_lists_cmake("4.4.4", "4.4.5")
    Open3.stubs(:capture3).with(*cache_env(dir), "brew", "update").returns(["", "fatal: unable to access\n", stub(success?: false)])

    When "installing"
    _out, err = capture_io { integration.install_all([legacy_cmake_pin("4.4.5")]) }

    Then
    1 * Open3.capture3(*cache_env(dir), "brew", "upgrade", "cmake") >> ["", "", stub(success?: true)]
    err.include?("brew update failed")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a keg still at another version after the upgrade fails with the re-lock remediation" do
    Given "brew's current formula is not the locked version either (the lock is behind brew), and no tap commit to pin"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    integration = converging_integration(dir, typed_mock(Dev::Deps::TapPinner))
    integration.stubs(:brew_installed?).returns(true)
    brew_lists_cmake("4.4.6")
    Open3.stubs(:capture3).with(*cache_env(dir), "brew", "update").returns(["", "", stub(success?: true)])
    Open3.stubs(:capture3).with(*cache_env(dir), "brew", "upgrade", "cmake").returns(["", "", stub(success?: true)])

    When "installing"
    capture_io { integration.install_all([legacy_cmake_pin("4.4.5")]) }

    Then "the mismatch names what brew has and what the lock pins, and points at dev deps update"
    error = raises Dev::Deps::Integration::PartialInstallError
    failure = error.failures.fetch(0).fetch(1)
    failure.is_a?(Dev::Deps::BrewIntegration::VersionMismatchError)
    failure.message.include?("cmake 4.4.6")
    failure.message.include?("4.4.5")
    failure.message.include?("dev deps update")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "pinned taps never converge: the tap at its locked commit is the whole install path" do
    Given "pinned mode, with the formula already present at another version"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    pinner = typed_mock(Dev::Deps::TapPinner)
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir), brew_prefix: dir,
      pin_taps: true, tap_pinner: pinner,
    )
    integration.stubs(:brew_installed?).returns(true)
    brew_lists_cmake("4.4.4")

    When "installing"
    integration.install_all([cmake_pin("4.4.5")])

    Then "the mismatch is reported as is; the tap stays pinned for the image, brew's index is left alone"
    1 * pinner.pin!("homebrew/core", COMMIT)
    0 * pinner.restore!(any_parameters)
    error = raises Dev::Deps::Integration::PartialInstallError
    error.failures.fetch(0).fetch(1).is_a?(Dev::Deps::BrewIntegration::VersionMismatchError)
    0 * Open3.capture3(*cache_env(dir), *PINNED_ENV, "brew", "install", any_parameters)
    0 * Open3.capture3(*cache_env(dir), *PINNED_ENV, "brew", "update")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "convergence writes escalate to the prefix owner like installs do" do
    Given "an unwritable brew prefix and a keg behind the lock"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    prefix = File.join(dir, "homebrew")
    FileUtils.mkdir_p(prefix)
    FileUtils.chmod(0o555, prefix)
    owner = Etc.getpwuid(File.stat(prefix).uid).name
    pinner = typed_mock(Dev::Deps::TapPinner)
    pinner.stubs(:pin!)
    pinner.stubs(:restore!)
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir), brew_prefix: prefix,
      tap_pinner: pinner,
    )
    integration.stubs(:brew_installed?).returns(true)
    brew_lists_cmake("4.4.4", "4.4.5")

    When "installing"
    capture_io { integration.install_all([cmake_pin("4.4.5")]) }

    Then
    1 * Open3.capture3("sudo", "-n", "-u", owner, *cache_env(dir), *PINNED_ENV, "brew", "install", "cmake") >> ["", "", stub(success?: true)]

    Cleanup
    FileUtils.chmod(0o755, prefix)
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

  # A fake Cellar: `<prefix>/Cellar/<formula>/<keg>/bin` for each keg named,
  # so activation can be tested against real directories.
  #
  # @param prefix [String] the fake brew prefix
  # @param kegs [Hash{String => Array<String>}] formula → keg directory names
  # @return [void]
  def lay_cellar(prefix, kegs)
    kegs.each do |formula, versions|
      versions.each { |version| FileUtils.mkdir_p(File.join(prefix, "Cellar", formula, version, "bin")) }
    end
  end

  # @param dir [String] project root
  # @return [String] what the brew activation file holds, "" when absent
  def brew_lisp(dir)
    path = File.join(dir, ".shadowenv.d", Dev::Deps::BrewIntegration::LISP_FILENAME)
    File.exist?(path) ? File.read(path) : ""
  end

  test "install_all activates the locked keg's bin, not the other kegs brew has" do
    Given "two kegs of cmake on the machine, the lock pinning the older one (brew revision suffix and all)"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    prefix = File.join(dir, "homebrew")
    lay_cellar(prefix, "cmake" => ["4.4.3_1", "4.5.0"])
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir),
      project_dir: dir, brew_prefix: prefix,
    )
    deps = [
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build,
        version: "4.4.3", hash: nil, metadata: {}),
    ]
    integration.stubs(:brew_installed?).returns(true)
    integration.stubs(:verify_installed!)

    When "installing all"
    integration.install_all(deps)

    Then "the project PATH gets the 4.4.3 keg and nothing of 4.5.0"
    _ * Kernel.system >> true
    brew_lisp(dir).include?(%((env/prepend-to-pathlist "PATH" "#{prefix}/Cellar/cmake/4.4.3_1/bin")))
    !brew_lisp(dir).include?("4.5.0")
    brew_lisp(dir).include?('(provide "brew" "cmake@4.4.3")')

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all activates versioned formulae under their formula name and skips kegs without a bin" do
    Given "llvm@18 with a bin and a library-only keg, both locked"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    prefix = File.join(dir, "homebrew")
    lay_cellar(prefix, "llvm@18" => ["18.1.8"])
    FileUtils.mkdir_p(File.join(prefix, "Cellar", "libyaml", "0.2.5", "lib"))
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir),
      project_dir: dir, brew_prefix: prefix,
    )
    deps = [
      Dev::Deps::Dependency.new(name: "llvm", integration: :brew, group: :build,
        version: "18.1.8", hash: nil, metadata: { "version_suffix" => "18" }),
      Dev::Deps::Dependency.new(name: "libyaml", integration: :brew, group: :build,
        version: "0.2.5", hash: nil, metadata: {}),
    ]
    integration.stubs(:brew_installed?).returns(true)
    integration.stubs(:verify_installed!)

    When "installing all"
    integration.install_all(deps)

    Then "only the keg with a bin is on PATH; the provide names both"
    _ * Kernel.system >> true
    brew_lisp(dir).include?(%("#{prefix}/Cellar/llvm@18/18.1.8/bin"))
    !brew_lisp(dir).include?("libyaml/0.2.5")
    brew_lisp(dir).include?('(provide "brew" "libyaml@0.2.5 llvm@18@18.1.8")')

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all activates nothing for casks or for a dep that locked no version" do
    Given "a cask and an unversioned tap formula"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    prefix = File.join(dir, "homebrew")
    lay_cellar(prefix, "wwise-cli" => ["0.3.0"])
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir),
      project_dir: dir, brew_prefix: prefix,
    )
    deps = [
      Dev::Deps::Dependency.new(name: "docker", integration: :cask, group: :default,
        version: nil, hash: nil, metadata: { "cask" => true }),
      Dev::Deps::Dependency.new(name: "wwise-cli", integration: :brew, group: :build,
        version: nil, hash: nil, metadata: { "tap" => "d3mlabs/d3mlabs" }),
    ]
    integration.stubs(:brew_installed?).returns(true)

    When "installing all"
    integration.install_all(deps)

    Then "the activation file names the unversioned formula and prepends nothing"
    _ * Kernel.system >> true
    brew_lisp(dir) == %((provide "brew" "wwise-cli")\n)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all hands an interpreter pin's keg to its language activation, after the PATH activation" do
    Given "a locked Ruby, its keg in the Cellar, and the Ruby activation as a collaborator"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    prefix = File.join(dir, "homebrew")
    lay_cellar(prefix, "ruby@4.0.9" => ["4.0.9"], "cmake" => ["4.4.3"])
    ruby_activation = typed_mock(Module)
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir),
      project_dir: dir, brew_prefix: prefix, interpreters: { ruby: ruby_activation },
    )
    deps = [
      Dev::Deps::Dependency.new(name: "ruby", integration: :ruby, group: :app,
        version: "4.0.9", hash: nil, metadata: { "tap" => "d3mlabs/d3mlabs", "version_suffix" => "4.0.9" }),
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build,
        version: "4.4.3", hash: nil, metadata: {}),
    ]
    integration.stubs(:brew_installed?).returns(true)
    integration.stubs(:verify_installed!)

    When "installing all"
    integration.install_all(deps)

    Then "the keg is on the project PATH like any formula, and the Ruby activation gets the keg and the locked version"
    _ * Kernel.system >> true
    1 * ruby_activation.activate!(keg: Pathname(prefix) / "Cellar" / "ruby@4.0.9" / "4.0.9", version: "4.0.9",
      project_root: Pathname(dir))
    brew_lisp(dir).include?(%("#{prefix}/Cellar/ruby@4.0.9/4.0.9/bin"))
    brew_lisp(dir).include?('(provide "brew" "cmake@4.4.3 ruby@4.0.9@4.0.9")')

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all raises when an interpreter pin's keg is not in the Cellar" do
    Given "a locked Python whose keg brew does not have"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    prefix = File.join(dir, "homebrew")
    python_activation = typed_mock(Module)
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir),
      project_dir: dir, brew_prefix: prefix, interpreters: { python: python_activation },
    )
    deps = [
      Dev::Deps::Dependency.new(name: "python", integration: :python, group: :app,
        version: "3.12.8", hash: nil, metadata: { "version_suffix" => "3.12" }),
    ]
    integration.stubs(:brew_installed?).returns(true)
    integration.stubs(:verify_installed!)

    When "installing all"
    integration.install_all(deps)

    Then "an interpreter with no keg to activate is an error, not a silent skip — nothing would run under it"
    _ * Kernel.system >> true
    0 * python_activation.activate!
    error = raises Dev::Deps::BrewIntegration::KegNotFoundError
    error.message.include?("python@3.12")
    error.message.include?("3.12.8")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all without a project dir neither activates nor retains" do
    Given "an integration built with no project (the image bootstrap's shape)"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    prefix = File.join(dir, "homebrew")
    lay_cellar(prefix, "cmake" => ["4.4.3"])
    brew_env = Dev::BrewEnv.new(path: Pathname(dir) / "brew.env")
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir),
      brew_prefix: prefix, brew_env: brew_env,
    )
    deps = [
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build,
        version: "4.4.3", hash: nil, metadata: {}),
    ]
    integration.stubs(:brew_installed?).returns(true)
    integration.stubs(:verify_installed!)

    When "installing all"
    integration.install_all(deps)

    Then "no shadowenv file and no brew.env were written"
    0 * Dev::ShadowenvPath.setup!
    !File.exist?(File.join(dir, "brew.env"))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all records every locked formula in brew's no-cleanup list, casks aside" do
    Given "a project with two formulae and a cask, and an empty brew.env"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    prefix = File.join(dir, "homebrew")
    lay_cellar(prefix, "cmake" => ["4.4.3"], "llvm@18" => ["18.1.8"])
    brew_env = Dev::BrewEnv.new(path: Pathname(dir) / "brew.env")
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir),
      project_dir: dir, brew_prefix: prefix, brew_env: brew_env,
    )
    deps = [
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build,
        version: "4.4.3", hash: nil, metadata: {}),
      Dev::Deps::Dependency.new(name: "llvm", integration: :brew, group: :build,
        version: "18.1.8", hash: nil, metadata: { "version_suffix" => "18" }),
      Dev::Deps::Dependency.new(name: "docker", integration: :cask, group: :default,
        version: nil, hash: nil, metadata: { "cask" => true }),
    ]
    integration.stubs(:brew_installed?).returns(true)
    integration.stubs(:verify_installed!)

    When "installing all"
    integration.install_all(deps)

    Then "brew is told to keep both formulae's kegs"
    _ * Kernel.system >> true
    brew_env.no_cleanup_formulae == ["cmake", "llvm@18"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all leaves brew.env alone when brew writes are escalated to another prefix owner" do
    Given "a prefix this user cannot write: brew.env is the owner's, not ours"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    prefix = File.join(dir, "homebrew")
    lay_cellar(prefix, "cmake" => ["4.4.3"])
    FileUtils.chmod(0o555, prefix)
    brew_env = Dev::BrewEnv.new(path: Pathname(dir) / "brew.env")
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir),
      project_dir: dir, brew_prefix: prefix, brew_env: brew_env,
    )
    deps = [
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build,
        version: "4.4.3", hash: nil, metadata: {}),
    ]
    integration.stubs(:brew_installed?).returns(true)
    integration.stubs(:verify_installed!)

    When "installing all"
    _out, err = capture_io { integration.install_all(deps) }

    Then "the keg is still activated for this project, retention is skipped and said so"
    _ * Kernel.system >> true
    brew_lisp(dir).include?("cmake/4.4.3/bin")
    !File.exist?(File.join(dir, "brew.env"))
    err.include?("brew.env")

    Cleanup
    FileUtils.chmod(0o755, prefix)
    FileUtils.rm_rf(dir)
  end

  test "install_all activates and retains what installed, then raises for what did not" do
    Given "two formulae, one of which brew fails to install"
    dir = Dir.mktmpdir("dev-brew-int-test-")
    prefix = File.join(dir, "homebrew")
    lay_cellar(prefix, "cmake" => ["4.4.3"])
    brew_env = Dev::BrewEnv.new(path: Pathname(dir) / "brew.env")
    integration = Dev::Deps::BrewIntegration.new(
      repository: Dev::Deps::BrewRepository.new, store: Dev::Deps::LocalStore.new(data_root: dir),
      project_dir: dir, brew_prefix: prefix, brew_env: brew_env,
    )
    deps = [
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build,
        version: "4.4.3", hash: nil, metadata: {}),
      Dev::Deps::Dependency.new(name: "ninja", integration: :brew, group: :build,
        version: "1.12.1", hash: nil, metadata: {}),
    ]
    integration.stubs(:brew_installed?).with("cmake").returns(true)
    integration.stubs(:brew_installed?).with("ninja").returns(false)
    integration.stubs(:verify_installed!)
    integration.stubs(:run_brew_install).with("ninja", "ninja").raises(Dev::Deps::BrewIntegration::InstallError, "boom")

    When "installing all"
    error = assert_raises(Dev::Deps::Integration::PartialInstallError) { integration.install_all(deps) }

    Then "cmake is on PATH and retained; ninja is in neither; the aggregate still raises"
    _ * Kernel.system >> true
    brew_lisp(dir).include?("cmake/4.4.3/bin")
    !brew_lisp(dir).include?("ninja")
    brew_env.no_cleanup_formulae == ["cmake"]
    error.message.include?("ninja")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "brew is the host prerequisite: the installer runs its batch before every other" do
    Expect
    Dev::Deps::BrewIntegration.host_prerequisite? == true
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

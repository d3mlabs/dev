# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/xcode_integration"
require "dev/deps/xcode_repository"
require "dev/deps/cache"
require "dev/deps/dependency"
require "tmpdir"
require "fileutils"

# XcodeIntegration with the OS boundaries (xcodes CLI, TTY detection, host
# check) replaced by canned values. The install root is a real tmpdir so the
# app-bundle presence checks run against the actual filesystem.
class FakeXcodeIntegration < Dev::Deps::XcodeIntegration
  attr_reader :install_invocations

  def initialize(darwin: true, interactive: false, xcodes_available: true, install_succeeds: true,
                 creates_app_on_install: true, **kwargs)
    super(**kwargs)
    @darwin = darwin
    @interactive = interactive
    @xcodes_available = xcodes_available
    @install_succeeds = install_succeeds
    @creates_app_on_install = creates_app_on_install
    @install_invocations = []
  end

  private

  def darwin? = @darwin
  def interactive? = @interactive
  def xcodes_available? = @xcodes_available

  def run_xcodes_install(version)
    @install_invocations << version
    FileUtils.mkdir_p(self.class.app_path(version, root: install_root)) if @creates_app_on_install
    @install_succeeds
  end
end unless defined?(FakeXcodeIntegration)

transform!(RSpock::AST::Transformation)
class Dev::Deps::XcodeIntegrationTest < Minitest::Test
  def build_dependency(version)
    Dev::Deps::Dependency.new(
      name: "xcode", integration: :xcode, group: :build,
      version: version, hash: nil, metadata: {},
    )
  end

  def build_integration(dir, **overrides)
    FakeXcodeIntegration.new(
      repository: Dev::Deps::XcodeRepository.new,
      cache: Dev::Deps::Cache.new(cache_dir: File.join(dir, "cache")),
      project_root: File.join(dir, "project"),
      install_root: File.join(dir, "Applications"),
      **overrides,
    )
  end

  test "install_all is a no-op off macOS" do
    Given "a non-darwin host"
    dir = Dir.mktmpdir("dev-xcode-int-test-")
    FileUtils.mkdir_p(File.join(dir, "project"))
    integration = build_integration(dir, darwin: false)

    When "installing"
    integration.install_all([build_dependency("26.1.1")])

    Then "xcodes is never invoked"
    integration.install_invocations.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "an already-present pin skips xcodes and still publishes DEVELOPER_DIR" do
    Given "the version-named bundle already exists (interactive bring-up did it)"
    dir = Dir.mktmpdir("dev-xcode-int-test-")
    FileUtils.mkdir_p(File.join(dir, "project"))
    integration = build_integration(dir)
    FileUtils.mkdir_p(Dev::Deps::XcodeIntegration.app_path("26.1.1", root: File.join(dir, "Applications")))

    When "installing"
    integration.install_all([build_dependency("26.1.1")])

    Then "no install runs, but the shadowenv lisp pins DEVELOPER_DIR"
    integration.install_invocations.empty?
    lisp = File.read(File.join(dir, "project", ".shadowenv.d", "520_xcode.lisp"))
    lisp.include?("DEVELOPER_DIR")
    lisp.include?(File.join(dir, "Applications", "Xcode-26.1.1.app", "Contents", "Developer"))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a missing pin installs via xcodes then publishes DEVELOPER_DIR" do
    Given "no bundle on disk and a working xcodes"
    dir = Dir.mktmpdir("dev-xcode-int-test-")
    FileUtils.mkdir_p(File.join(dir, "project"))
    integration = build_integration(dir)

    When "installing"
    integration.install_all([build_dependency("26.1.1")])

    Then "xcodes ran once for the pinned version and the env is published"
    integration.install_invocations == ["26.1.1"]
    File.exist?(File.join(dir, "project", ".shadowenv.d", "520_xcode.lisp"))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a missing xcodes CLI raises with the dependencies.rb remediation" do
    Given "no bundle and no xcodes CLI"
    dir = Dir.mktmpdir("dev-xcode-int-test-")
    integration = build_integration(dir, xcodes_available: false)

    When "installing"
    error = assert_raises(Dev::Deps::XcodeIntegration::XcodesMissingError) do
      integration.install_all([build_dependency("26.1.1")])
    end

    Then "the message points at the brew declaration"
    error.message.include?("xcodes CLI is not installed")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a headless install failure raises with the remediation menu" do
    Given "xcodes fails without a TTY (it hit a prompt and read EOF)"
    dir = Dir.mktmpdir("dev-xcode-int-test-")
    integration = build_integration(dir, interactive: false, install_succeeds: false,
                                         creates_app_on_install: false)

    When "installing"
    error = assert_raises(Dev::Deps::XcodeIntegration::InstallError) do
      integration.install_all([build_dependency("26.1.1")])
    end

    Then "the message carries the headless remediations"
    error.message.include?("headless")
    error.message.include?("pre-install the pin interactively")

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "fileutils"
require "pathname"
require "dev/container_dev_provisioner"
require "support/fake_container_engine"

transform!(RSpock::AST::Transformation)
class Dev::ContainerDevProvisionerTest < Minitest::Test
  include SorbetHelper

  SCRIPT = Dev::ContainerDevProvisioner::SCRIPT

  # brew, git and dev as shell functions, prepended to the script's text so a
  # test can run the whole provision (see the file's header for why functions
  # and not a PATH shim).
  STUBBED_TOOLS = Pathname.new(File.expand_path("../support/container_provision_stubs.sh", __dir__))

  test "provision! is a no-op when the container's dev already reports the host's version" do
    Given "a container whose dev version equals the host's"
    engine = FakeContainerEngine.new(capture_result: "0.2.98\n")
    provisioner = Dev::ContainerDevProvisioner.new(engine: engine, host_version: "0.2.98")

    When "provisioning"
    result = provisioner.provision!("dev-snappy-abc-content-123")

    Then "the version was probed with docker exec and nothing was installed"
    result == :current
    engine.captures == [["exec", "dev-snappy-abc-content-123", "dev", "version"]]
    engine.runs.empty?
  end

  test "provision! installs the host's version when the container reports #{reported.inspect}" do
    Given "a container whose dev is #{label}"
    engine = FakeContainerEngine.new(capture_result: reported)
    provisioner = Dev::ContainerDevProvisioner.new(engine: engine, host_version: "0.2.98")

    When "provisioning"
    result = provisioner.provision!("dev-x")

    Then "the install script runs inside the container with the host's version as its argument"
    result == :installed
    engine.runs == [["exec", "dev-x", "sh", "-c", SCRIPT.read, "sh", "0.2.98"]]

    Where
    reported     | label
    ""           | "absent (the probe fails)"
    "0.2.97\n"   | "an older release"
    "0.2.99\n"   | "a newer release"
  end

  test "provision! raises ProvisionFailedError, naming container and version, when the install fails" do
    Given "an engine whose exec fails"
    engine = FakeContainerEngine.new(capture_result: "") { |_args| false }
    provisioner = Dev::ContainerDevProvisioner.new(engine: engine, host_version: "0.2.98")

    When "provisioning"
    provisioner.provision!("dev-x")

    Then
    error = raises Dev::ContainerDevProvisioner::ProvisionFailedError
    error.message.include?("dev-x")
    error.message.include?("0.2.98")
  end

  test "the install script is POSIX sh, takes the version as $1, and pins the tap at the release that shipped it" do
    Given "the script shipped beside dev's bin"
    script = SCRIPT.read

    Expect "its contract, readable from the text"
    script.start_with?("#!/bin/sh")
    script.include?("version=\"$1\"")
    script.include?("Formula/dev-core.rb")
    script.include?("brew install")
    SCRIPT.executable?
  end

  test "the install script re-syncs with brew reinstall, never uninstall: dev-core's dependencies stay put" do
    Given "the script shipped beside dev's bin"
    script = SCRIPT.read

    Expect "a swap of dev-core, not a removal that autoremoves ruby, shadowenv, git, gh … with it"
    script.include?("brew reinstall --quiet d3mlabs/d3mlabs/dev-core")
    !script.include?("brew uninstall")
  end

  test "the install script bootstraps Linuxbrew into the container's own prefix when the image carries none (ADR-0008)" do
    Given "the script shipped beside dev's bin, and the image bootstrap it takes the installer pin from"
    script = SCRIPT.read
    image_bootstrap = File.read(File.expand_path("../../bin/docker-install-build-deps.sh", __dir__))
    pin = image_bootstrap[%r{Homebrew/install/([0-9a-f]{40})/install\.sh}, 1]

    Expect "a missing brew is installed, not a hard stop; non-interactively, from the same pinned installer commit, trusted and tapped before dev-core"
    !script.include?("the image must carry Linuxbrew")
    script.include?("if ! command -v brew")
    script.include?("NONINTERACTIVE=1")
    script.include?("https://raw.githubusercontent.com/Homebrew/install/#{pin}/install.sh")
    script.index("brew trust d3mlabs/d3mlabs") < script.index("brew tap --quiet d3mlabs/d3mlabs")
  end

  test "the install script hardens a #{initial_mode} ~/.homebrew to #{hardened_mode} before its first brew call (Homebrew >= 7.0.11 refuses group-writable)" do
    Given "a home whose trust-store dir and brew.env carry mode #{initial_mode}/#{initial_file_mode}, and a tap dir"
    home = Dir.mktmpdir("dev-provision-home-")
    tap_dir = Dir.mktmpdir("dev-provision-tap-")
    trust_store = File.join(home, ".homebrew")
    brew_env = File.join(trust_store, "brew.env")
    Dir.mkdir(trust_store)
    File.write(brew_env, "")
    File.chmod(initial_mode.to_i(8), trust_store)
    File.chmod(initial_file_mode.to_i(8), brew_env)
    brew_calls = File.join(home, "brew-calls.log")

    When "the script provisions 0.2.98 with brew, git and dev stubbed as shell functions ahead of its text"
    _out, _err, status = Open3.capture3(
      { "HOME" => home, "DEV_TEST_TAP_DIR" => tap_dir, "DEV_TEST_BREW_CALLS" => brew_calls },
      "sh", "-c", STUBBED_TOOLS.read + SCRIPT.read, "sh", "0.2.98"
    )

    Then "the provision succeeds, the dir and its entries lost their group/world write bits, and the dir was already hardened when brew first ran"
    status.success?
    format("%o", File.stat(trust_store).mode & 0o777) == hardened_mode
    format("%o", File.stat(brew_env).mode & 0o777) == hardened_file_mode
    File.readlines(brew_calls, chomp: true).first == "--repo d3mlabs/d3mlabs #{hardened_listing}"

    Cleanup
    FileUtils.rm_rf(home)
    FileUtils.rm_rf(tap_dir)

    Where
    initial_mode | initial_file_mode | hardened_mode | hardened_file_mode | hardened_listing
    "775"        | "664"             | "755"         | "644"              | "drwxr-xr-x"
    "755"        | "644"             | "755"         | "644"              | "drwxr-xr-x"
    "700"        | "600"             | "700"         | "600"              | "drwx------"
  end

  test "the install script creates a missing ~/.homebrew owner-writable only, so a 002 umask cannot leave it group-writable" do
    Given "a home with no trust-store dir and a 002 umask"
    home = Dir.mktmpdir("dev-provision-home-")
    tap_dir = Dir.mktmpdir("dev-provision-tap-")
    brew_calls = File.join(home, "brew-calls.log")

    When "the script provisions 0.2.98 under that umask"
    _out, _err, status = Open3.capture3(
      { "HOME" => home, "DEV_TEST_TAP_DIR" => tap_dir, "DEV_TEST_BREW_CALLS" => brew_calls },
      "sh", "-c", "umask 002\n" + STUBBED_TOOLS.read + SCRIPT.read, "sh", "0.2.98"
    )

    Then "the provision succeeds and the dir it created has no group/world write bits"
    status.success?
    format("%o", File.stat(File.join(home, ".homebrew")).mode & 0o777) == "755"

    Cleanup
    FileUtils.rm_rf(home)
    FileUtils.rm_rf(tap_dir)
  end

  test "the install script parses under sh -n" do
    Expect "a clean syntax check"
    system("sh", "-n", SCRIPT.to_s)
  end
end

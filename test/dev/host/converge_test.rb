# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/host/converge"
require "dev/settings"
require "fileutils"
require "stringio"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Host::ConvergeTest < Minitest::Test
  # Records every brew invocation instead of running it — the executor is
  # the true boundary; everything else (settings layers, Brewfile, stamp)
  # uses real files in temp dirs.
  class RecordingExecutor
    attr_reader :commands

    def initialize(run_result: true, quiet_result: false)
      @commands = []
      @run_result = run_result
      @quiet_result = quiet_result
    end

    def run(*cmd)
      @commands << cmd
      @run_result
    end

    def quiet?(*cmd)
      @commands << cmd
      @quiet_result
    end
  end

  test "run is a no-op on a brewless machine (no system config location)" do
    Given "settings that resolve no brew prefix"
    dir = Dir.mktmpdir("dev-host-converge-test-")
    executor = RecordingExecutor.new
    converge = build_converge(dir, executor: executor)
    converge.instance_variable_get(:@settings).stubs(:system_config_path).returns(nil)

    When "converging"
    converge.run

    Then "brew is never invoked"
    executor.commands.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "first run performs the throttled self-update and stamps, but has nothing to upgrade" do
    Given "no deployment config, no Brewfile, dev-core not brew-installed"
    dir = Dir.mktmpdir("dev-host-converge-test-")
    executor = RecordingExecutor.new(quiet_result: false)
    converge = build_converge(dir, executor: executor)

    When "converging"
    converge.run

    Then "brew update + the dev-core check ran, nothing upgraded or bundled, and the throttle stamp exists"
    executor.commands == [
      ["brew", "update", "--quiet"],
      ["brew", "list", "--formula", "--versions", "dev-core"],
    ]
    File.exist?(File.join(dir, "state", "host", "brew-update-stamp"))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a named deployment upgrades exactly that formula" do
    Given "a system config naming the deployment"
    dir = Dir.mktmpdir("dev-host-converge-test-")
    write_system_config(dir, "deployment_formula: d3mlabs/d3mlabs/dev\n")
    executor = RecordingExecutor.new
    converge = build_converge(dir, executor: executor)

    When "converging"
    stderr = capture_stderr { converge.run }

    Then "the scoped upgrade targets the self-named formula, with no warning"
    executor.commands.include?(["brew", "upgrade", "--quiet", "d3mlabs/d3mlabs/dev"])
    stderr.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a malformed deployment_formula never reaches brew" do
    Given "a hostile value that would parse as a brew flag"
    dir = Dir.mktmpdir("dev-host-converge-test-")
    write_system_config(dir, 'deployment_formula: "--force evil"' + "\n")
    executor = RecordingExecutor.new
    converge = build_converge(dir, executor: executor)

    When "converging"
    stderr = capture_stderr { converge.run }

    Then "no upgrade is attempted and the rejection is warned"
    executor.commands.none? { |cmd| cmd[0..1] == ["brew", "upgrade"] }
    stderr.include?("malformed deployment_formula")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "an unset key falls back to dev-core when it is brew-installed" do
    Given "no deployment config, dev-core installed"
    dir = Dir.mktmpdir("dev-host-converge-test-")
    executor = RecordingExecutor.new(quiet_result: true)
    converge = build_converge(dir, executor: executor)

    When "converging"
    converge.run

    Then "the tapless individual's tool self-updates"
    executor.commands.include?(["brew", "upgrade", "--quiet", "dev-core"])

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a warm rerun inside the throttle window skips the self-update but still converges the Brewfile" do
    Given "a fresh throttle stamp and an org Brewfile"
    dir = Dir.mktmpdir("dev-host-converge-test-")
    stamp = File.join(dir, "state", "host", "brew-update-stamp")
    FileUtils.mkdir_p(File.dirname(stamp))
    FileUtils.touch(stamp)
    brewfile = write_brewfile(dir, %(cask "cursor-cli"\n))
    executor = RecordingExecutor.new
    converge = build_converge(dir, executor: executor)

    When "converging"
    converge.run

    Then "no update or upgrade, but the Brewfile converge is never throttled"
    executor.commands == [["brew", "bundle", "install", "--file=#{brewfile}"]]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "an expired throttle stamp re-runs the self-update" do
    Given "a stamp older than the update interval"
    dir = Dir.mktmpdir("dev-host-converge-test-")
    stamp = File.join(dir, "state", "host", "brew-update-stamp")
    FileUtils.mkdir_p(File.dirname(stamp))
    FileUtils.touch(stamp)
    late_clock = -> { Time.now + Dev::Host::Converge::UPDATE_INTERVAL_SECONDS + 1 }
    executor = RecordingExecutor.new
    converge = build_converge(dir, executor: executor, clock: late_clock)

    When "converging a day later"
    converge.run

    Then "brew update ran again"
    executor.commands.first == ["brew", "update", "--quiet"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a failed brew update warns and skips the upgrade without stamping, so the next run retries" do
    Given "an offline machine (every streamed brew command fails)"
    dir = Dir.mktmpdir("dev-host-converge-test-")
    write_system_config(dir, "deployment_formula: d3mlabs/d3mlabs/dev\n")
    executor = RecordingExecutor.new(run_result: false)
    converge = build_converge(dir, executor: executor)

    When "converging"
    stderr = capture_stderr { converge.run }

    Then "no upgrade was attempted, the failure is a warning, and no stamp was written"
    executor.commands.none? { |cmd| cmd[0..1] == ["brew", "upgrade"] }
    stderr.include?("brew update failed")
    !File.exist?(File.join(dir, "state", "host", "brew-update-stamp"))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "an etc config.yml without a resolvable deployment_formula warns with the remedy" do
    Given "a deployment config that forgot to name itself"
    dir = Dir.mktmpdir("dev-host-converge-test-")
    write_system_config(dir, "plans_repo: acme/plans\n")
    converge = build_converge(dir, executor: RecordingExecutor.new)

    When "converging"
    stderr = capture_stderr { converge.run }

    Then "the warning names the failure and the one-command fix"
    stderr.include?("no deployment_formula is set")
    stderr.include?("dev config set deployment_formula")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the unnamed-deployment warning is silenced by a higher layer naming it" do
    Given "a keyless system config but a user file naming the deployment"
    dir = Dir.mktmpdir("dev-host-converge-test-")
    write_system_config(dir, "plans_repo: acme/plans\n")
    write_user_config(dir, "deployment_formula: acme/tap/dev\n")
    executor = RecordingExecutor.new
    converge = build_converge(dir, executor: executor)

    When "converging"
    stderr = capture_stderr { converge.run }

    Then "no warning, and the user-layer target is upgraded"
    stderr.empty?
    executor.commands.include?(["brew", "upgrade", "--quiet", "acme/tap/dev"])

    Cleanup
    FileUtils.rm_rf(dir)
  end

  private

  # Hermetic converge: settings layers, throttle stamp, and Brewfile all
  # live under the test's temp dir; only the executor is faked.
  def build_converge(dir, executor:, clock: -> { Time.now })
    settings = Dev::Settings.new(
      config_path: File.join(dir, "user", "config.yml"),
      system_config_path: File.join(dir, "etc", "config.yml"),
    )
    Dev::Host::Converge.new(
      settings: settings,
      state_dir: File.join(dir, "state"),
      executor: executor,
      clock: clock,
    )
  end

  def write_system_config(dir, content)
    path = File.join(dir, "etc", "config.yml")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def write_user_config(dir, content)
    path = File.join(dir, "user", "config.yml")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  # @return [String] the Brewfile path (beside the system config, as a
  #   deployment ships it)
  def write_brewfile(dir, content)
    path = File.join(dir, "etc", "Brewfile")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def capture_stderr
    old_stderr = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old_stderr
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/host/converge"
require "dev/settings"
require "fileutils"
require "rbconfig"
require "stringio"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Host::ConvergeTest < Minitest::Test
  # Records every brew invocation instead of running it — the executor is
  # the true boundary; everything else (settings layers, Brewfile) uses
  # real files in temp dirs.
  class RecordingExecutor
    attr_reader :commands

    # @param fail_subcommands [Array<String>] brew subcommands whose run
    #   reports failure (e.g. ["upgrade"]), for the warn-only branches
    def initialize(run_result: true, quiet_result: false, fail_subcommands: [])
      @commands = []
      @run_result = run_result
      @quiet_result = quiet_result
      @fail_subcommands = fail_subcommands
    end

    def run(*cmd)
      @commands << cmd
      return false if @fail_subcommands.include?(cmd[1])

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

  test "a bare host runs the self-update but has nothing to upgrade or bundle" do
    Given "no deployment config, no Brewfile, dev-core not brew-installed"
    dir = Dir.mktmpdir("dev-host-converge-test-")
    executor = RecordingExecutor.new(quiet_result: false)
    converge = build_converge(dir, executor: executor)

    When "converging"
    converge.run

    Then "brew update + the dev-core check ran, nothing upgraded or bundled"
    executor.commands == [
      ["brew", "update", "--quiet"],
      ["brew", "list", "--formula", "--versions", "dev-core"],
    ]

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

  test "'#{formula}' (#{shape}) keeps its spelling through to brew upgrade" do
    Given "a deployment named with that token shape"
    dir = Dir.mktmpdir("dev-host-converge-test-")
    write_system_config(dir, "deployment_formula: #{formula}\n")
    executor = RecordingExecutor.new
    converge = build_converge(dir, executor: executor)

    When "converging"
    stderr = capture_stderr { converge.run }

    Then "the scoped upgrade targets the formula as spelled, with no warning"
    executor.commands.include?(["brew", "upgrade", "--quiet", formula])
    stderr.empty?

    Cleanup
    FileUtils.rm_rf(dir)

    Where
    formula             | shape
    "d3mlabs/tap/dev@2" | "tap-qualified versioned"
    "org/tap/libc++"    | "tap-qualified plused"
  end

  test "'#{formula}' (#{reason}) is rejected as malformed" do
    Given "a deployment_formula that is not a canonical brew token"
    dir = Dir.mktmpdir("dev-host-converge-test-")
    write_system_config(dir, "deployment_formula: #{formula}\n")
    executor = RecordingExecutor.new
    converge = build_converge(dir, executor: executor)

    When "converging"
    stderr = capture_stderr { converge.run }

    Then "no upgrade is attempted and the rejection is warned"
    executor.commands.none? { |cmd| cmd[0..1] == ["brew", "upgrade"] }
    stderr.include?("malformed deployment_formula")

    Cleanup
    FileUtils.rm_rf(dir)

    Where
    formula    | reason
    "foo/bar"  | "two segments is not a formula reference"
    "Dev-Core" | "brew's canonical tap form is lowercase"
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

  test "a Brewfile beside the system config converges via brew bundle" do
    Given "an org Brewfile in etc"
    dir = Dir.mktmpdir("dev-host-converge-test-")
    brewfile = write_brewfile(dir, %(cask "cursor-cli"\n))
    executor = RecordingExecutor.new(quiet_result: false)
    converge = build_converge(dir, executor: executor)

    When "converging"
    converge.run

    Then "brew bundle runs against the etc Brewfile as the last step"
    executor.commands.last == ["brew", "bundle", "install", "--file=#{brewfile}"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a failed scoped upgrade warns and still converges the Brewfile" do
    Given "a named deployment whose upgrade fails"
    dir = Dir.mktmpdir("dev-host-converge-test-")
    write_system_config(dir, "deployment_formula: d3mlabs/d3mlabs/dev\n")
    brewfile = write_brewfile(dir, %(cask "cursor-cli"\n))
    executor = RecordingExecutor.new(fail_subcommands: ["upgrade"])
    converge = build_converge(dir, executor: executor)

    When "converging"
    stderr = capture_stderr { converge.run }

    Then "the failure is a warning and the Brewfile step still ran"
    stderr.include?("brew upgrade d3mlabs/d3mlabs/dev failed")
    executor.commands.last == ["brew", "bundle", "install", "--file=#{brewfile}"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a failed brew bundle warns instead of blocking" do
    Given "an org Brewfile whose converge fails"
    dir = Dir.mktmpdir("dev-host-converge-test-")
    write_brewfile(dir, %(cask "cursor-cli"\n))
    executor = RecordingExecutor.new(quiet_result: false, fail_subcommands: ["bundle"])
    converge = build_converge(dir, executor: executor)

    When "converging"
    stderr = capture_stderr { converge.run }

    Then "the failure surfaces as a warning naming the Brewfile"
    stderr.include?("brew bundle failed")
    stderr.include?("Brewfile")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a failed brew update warns and skips the upgrade, but the Brewfile still converges" do
    Given "an offline machine (every streamed brew command fails)"
    dir = Dir.mktmpdir("dev-host-converge-test-")
    write_system_config(dir, "deployment_formula: d3mlabs/d3mlabs/dev\n")
    executor = RecordingExecutor.new(run_result: false)
    converge = build_converge(dir, executor: executor)

    When "converging"
    stderr = capture_stderr { converge.run }

    Then "no upgrade was attempted and the failure is a warning"
    executor.commands.none? { |cmd| cmd[0..1] == ["brew", "upgrade"] }
    stderr.include?("brew update failed")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the real executor's run maps exit status to a boolean" do
    Given "the production executor"
    executor = Dev::Host::Converge::Executor.new

    Expect "success and failure map to booleans, and a missing binary is false"
    executor.run(RbConfig.ruby, "-e", "exit 0") == true
    executor.run(RbConfig.ruby, "-e", "exit 1") == false
    executor.run("definitely-not-a-command-#{Process.pid}") == false
  end

  test "the real executor's quiet? answers success without streaming output" do
    Given "the production executor"
    executor = Dev::Host::Converge::Executor.new

    Expect "exit status maps to a boolean and a missing binary is false, not an exception"
    executor.quiet?(RbConfig.ruby, "-e", "puts :ok") == true
    executor.quiet?(RbConfig.ruby, "-e", "exit 1") == false
    executor.quiet?("definitely-not-a-command-#{Process.pid}") == false
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

  # Hermetic converge: settings layers and Brewfile live under the test's
  # temp dir; only the executor is faked.
  def build_converge(dir, executor:)
    settings = Dev::Settings.new(
      config_path: File.join(dir, "user", "config.yml"),
      system_config_path: File.join(dir, "etc", "config.yml"),
    )
    Dev::Host::Converge.new(settings: settings, executor: executor)
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

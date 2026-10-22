# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/privileged_steps"
require "tmpdir"
require "fileutils"

# Records every invocation; sudo is the true boundary. +failing+ names the
# streamed command (by substring) that fails.
class RecordedSudoExecutor
  attr_reader :runs

  def initialize(failing: nil)
    @failing = failing
    @runs = []
  end

  def run(*cmd)
    @runs << cmd
    @failing.nil? || !cmd.join(" ").include?(@failing)
  end
end unless defined?(RecordedSudoExecutor)

transform!(RSpock::AST::Transformation)
class Dev::PrivilegedStepsTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("privileged-steps-test-")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  test "an interactive session asks once with `sudo -v`" do
    Given "a terminal"
    executor = RecordedSudoExecutor.new
    steps = Dev::PrivilegedSteps.new(executor: executor, tty: true)

    When "opening the session"
    steps.session!

    Then "the one prompt ran"
    executor.runs == [%w[sudo -v]]

    Cleanup
    nil
  end

  test "a declined interactive prompt is a failed step naming it" do
    Given "a terminal and a user who declines"
    executor = RecordedSudoExecutor.new(failing: "sudo -v")
    steps = Dev::PrivilegedSteps.new(executor: executor, tty: true)

    When "opening the session"
    error = assert_raises(Dev::PrivilegedSteps::StepFailedError) { steps.session! }

    Then "the message carries the argv"
    error.message.include?("sudo -v")

    Cleanup
    nil
  end

  test "a headless session never prompts: `sudo -n -v`, and passwordless sudo passes" do
    Given "no terminal (a CI job) on a host with passwordless sudo"
    executor = RecordedSudoExecutor.new
    steps = Dev::PrivilegedSteps.new(executor: executor, tty: false)

    When "opening the session"
    steps.session!

    Then "the non-interactive validation ran and nothing waited on a password"
    executor.runs == [%w[sudo -n -v]]

    Cleanup
    nil
  end

  test "a headless session on a host that would prompt fails at once with the way out" do
    Given "no terminal and sudo wanting a password"
    executor = RecordedSudoExecutor.new(failing: "sudo -n -v")
    steps = Dev::PrivilegedSteps.new(executor: executor, tty: false, purpose: "install winehq-stable")

    When "opening the session"
    error = assert_raises(Dev::PrivilegedSteps::SudoRequiredError) { steps.session! }

    Then "the error names the work and the one interactive `dev up` that unblocks it"
    error.message.include?("install winehq-stable")
    error.message.include?("dev up")
    error.message.include?("interactively")
    executor.runs == [%w[sudo -n -v]]

    Cleanup
    nil
  end

  test "step! runs the argv as given and names it when it fails" do
    Given "an executor where apt-get update fails"
    executor = RecordedSudoExecutor.new(failing: "apt-get update")
    steps = Dev::PrivilegedSteps.new(executor: executor, tty: true)

    When "running a passing step then the failing one"
    steps.step!("sudo", "apt-get", "install", "-y", "xvfb")
    error = assert_raises(Dev::PrivilegedSteps::StepFailedError) { steps.step!("sudo", "apt-get", "update") }

    Then "both ran, the message carries the failing argv"
    executor.runs == [%w[sudo apt-get install -y xvfb], %w[sudo apt-get update]]
    error.message.include?("sudo apt-get update")

    Cleanup
    nil
  end

  test "install_file! stages the content and installs it root-owned at the mode asked" do
    Given "content for a root-owned file"
    executor = RecordedSudoExecutor.new
    steps = Dev::PrivilegedSteps.new(executor: executor, tty: true)
    target = File.join(@dir, "etc", "apt", "sources.list.d", "winehq.sources")

    When "installing it"
    steps.install_file!("Types: deb\n", target, mode: "0644")

    Then "one `sudo install -m` step ran from a staged copy holding exactly that content"
    executor.runs.size == 1
    executor.runs.first.values_at(0, 1, 2, 3, 5) == ["sudo", "install", "-m", "0644", target]
    File.read(executor.runs.first[4]) == "Types: deb\n"

    Cleanup
    nil
  end
end

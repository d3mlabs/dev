# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/agent_bootstrap"
require "stringio"

# Records every host invocation; the admin CLIs (sysadminctl, dseditgroup,
# visudo, ...) are a true boundary — tests never mutate the host.
class RecordedBootstrapExecutor
  attr_reader :runs, :probes

  # @param probe_results [Hash{Array<String> => Boolean}] quiet? answers (default false)
  # @param capture_results [Hash{Array<String> => String}] capture answers (default "")
  # @param fail_matching [String, nil] run() fails when the argv mentions this token
  def initialize(probe_results: {}, capture_results: {}, fail_matching: nil)
    @probe_results = probe_results
    @capture_results = capture_results
    @fail_matching = fail_matching
    @runs = []
    @probes = []
  end

  def run(*cmd)
    @runs << cmd
    return false if @fail_matching && cmd.any? { |arg| arg.include?(@fail_matching) }

    true
  end

  def quiet?(*cmd)
    @probes << cmd
    @probe_results.fetch(cmd, false)
  end

  def capture(*cmd)
    @capture_results.fetch(cmd, "")
  end
end unless defined?(RecordedBootstrapExecutor)

transform!(RSpock::AST::Transformation)
class Dev::AgentBootstrapTest < Minitest::Test
  def bootstrap(executor, darwin: true, **kwargs)
    Dev::AgentBootstrap.new(
      runner_user: "human", executor: executor, out: StringIO.new, darwin: darwin, **kwargs,
    )
  end

  test "converge! raises off macOS" do
    Given "a non-darwin host"
    executor = RecordedBootstrapExecutor.new

    When "converging"
    bootstrap(executor, darwin: false).converge!

    Then
    raises Dev::AgentBootstrap::UnsupportedPlatformError
  end

  test "converge! is a no-op when the posture already holds" do
    Given "a host where every probe answers converged"
    executor = RecordedBootstrapExecutor.new(
      probe_results: {
        ["id", "-u", "ai-agent"] => true,
        ["dseditgroup", "-o", "read", "ai"] => true,
        ["dseditgroup", "-o", "checkmember", "-m", "human", "ai"] => true,
        ["dseditgroup", "-o", "checkmember", "-m", "ai-agent", "ai"] => true,
      },
      capture_results: {
        ["sudo", "cat", "/etc/sudoers.d/ai-flow-agent"] =>
          Dev::AgentBootstrap.new(runner_user: "human", darwin: true).sudoers_content,
      },
    )

    When "converging"
    bootstrap(executor).converge!

    Then "nothing was mutated"
    executor.runs.empty?
  end

  test "converge! creates the hidden non-admin agent user with its own home" do
    Given "a host missing only the agent user"
    executor = RecordedBootstrapExecutor.new(
      probe_results: {
        ["dseditgroup", "-o", "read", "ai"] => true,
        ["dseditgroup", "-o", "checkmember", "-m", "human", "ai"] => true,
        ["dseditgroup", "-o", "checkmember", "-m", "ai-agent", "ai"] => true,
      },
      capture_results: {
        ["sudo", "cat", "/etc/sudoers.d/ai-flow-agent"] =>
          Dev::AgentBootstrap.new(runner_user: "human", darwin: true).sudoers_content,
      },
    )

    When "converging"
    bootstrap(executor).converge!

    Then "sysadminctl creates, dscl hides, createhomedir materializes"
    executor.runs == [
      ["sudo", "sysadminctl", "-addUser", "ai-agent", "-fullName", "AI Agent", "-shell", "/bin/zsh"],
      ["sudo", "dscl", ".", "create", "/Users/ai-agent", "IsHidden", "1"],
      ["sudo", "createhomedir", "-c", "-u", "ai-agent"],
    ]
  end

  test "converge! creates the ai group and enrolls both identities" do
    Given "a host missing the group"
    executor = RecordedBootstrapExecutor.new(
      probe_results: { ["id", "-u", "ai-agent"] => true },
      capture_results: {
        ["sudo", "cat", "/etc/sudoers.d/ai-flow-agent"] =>
          Dev::AgentBootstrap.new(runner_user: "human", darwin: true).sudoers_content,
      },
    )

    When "converging"
    bootstrap(executor).converge!

    Then
    executor.runs == [
      ["sudo", "dseditgroup", "-o", "create", "ai"],
      ["sudo", "dseditgroup", "-o", "edit", "-a", "human", "-t", "user", "ai"],
      ["sudo", "dseditgroup", "-o", "edit", "-a", "ai-agent", "-t", "user", "ai"],
    ]
  end

  test "converge! writes the sudoers drop-in only after visudo validates it" do
    Given "a host missing only the sudoers drop-in"
    executor = RecordedBootstrapExecutor.new(
      probe_results: {
        ["id", "-u", "ai-agent"] => true,
        ["dseditgroup", "-o", "read", "ai"] => true,
        ["dseditgroup", "-o", "checkmember", "-m", "human", "ai"] => true,
        ["dseditgroup", "-o", "checkmember", "-m", "ai-agent", "ai"] => true,
      },
    )

    When "converging"
    bootstrap(executor).converge!

    Then "validate on a staging file, then install root-owned 0440"
    executor.runs.length == 2
    executor.runs.fetch(0).first(4) == ["sudo", "visudo", "-c", "-f"]
    executor.runs.fetch(1).first(6) ==
      ["sudo", "install", "-m", "0440", "-o", "root"]
    executor.runs.fetch(1).last == "/etc/sudoers.d/ai-flow-agent"
  end

  test "converge! raises and never installs when visudo rejects the drop-in" do
    Given "visudo failing"
    executor = RecordedBootstrapExecutor.new(
      fail_matching: "visudo",
      probe_results: {
        ["id", "-u", "ai-agent"] => true,
        ["dseditgroup", "-o", "read", "ai"] => true,
        ["dseditgroup", "-o", "checkmember", "-m", "human", "ai"] => true,
        ["dseditgroup", "-o", "checkmember", "-m", "ai-agent", "ai"] => true,
      },
    )

    When "converging"
    bootstrap(executor).converge!

    Then "it raises and no install ran"
    raises Dev::AgentBootstrap::StepFailedError
  end

  test "sudoers content grants the one-way SETENV edge with the agent umask defaults" do
    Given "a bootstrap"
    content = Dev::AgentBootstrap.new(runner_user: "human", darwin: true).sudoers_content

    Expect
    content.include?("human ALL=(ai-agent) NOPASSWD:SETENV: ALL")
    content.include?("Defaults>ai-agent env_reset, umask=0002, umask_override")
    content.end_with?("\n")
  end

  test "the agent user is a register-time parameter" do
    Given "an overridden run-as user"
    executor = RecordedBootstrapExecutor.new

    When "converging"
    bootstrap(executor, agent_user: "ci").converge!

    Then "every step targets the override"
    executor.runs.fetch(0) ==
      ["sudo", "sysadminctl", "-addUser", "ci", "-fullName", "AI Agent", "-shell", "/bin/zsh"]
    executor.probes.include?(["id", "-u", "ci"])
  end
end

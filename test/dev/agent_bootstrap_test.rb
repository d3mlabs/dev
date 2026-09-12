# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/agent_bootstrap"
require "stringio"
require "tmpdir"

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

  def run(*cmd, chdir: nil)
    @runs << (chdir ? cmd + [{ chdir: chdir }] : cmd)
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
  # Filesystem-facing params always point at tmp paths: an already-provisioned
  # shared root (DDC dir included) and no ~/.dev to migrate, so identity-step
  # tests stay focused.
  def bootstrap(executor, darwin: true, **kwargs)
    provisioned_root = Dir.mktmpdir.tap { |root| FileUtils.mkdir_p(File.join(root, "ddc")) }
    defaults = { shared_root: provisioned_root, home_dev: File.join(Dir.mktmpdir, "absent-home-dev") }
    Dev::AgentBootstrap.new(
      runner_user: "human", executor: executor, out: StringIO.new, darwin: darwin,
      **defaults.merge(kwargs)
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

  test "converge! is a no-op when the host is already converged" do
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

  test "converge! provisions a fresh shared root with cooperative modes" do
    Given "converged identities but no shared root"
    executor = converged_identity_executor
    shared_root = File.join(Dir.mktmpdir, "dev")

    When "converging"
    bootstrap(executor, shared_root: shared_root).converge!

    Then "root and DDC dir exist, human-owned, group ai, setgid group-writable"
    File.directory?(shared_root)
    File.directory?(File.join(shared_root, "ddc"))
    executor.runs == [
      ["sudo", "chown", "human", shared_root],
      ["sudo", "chgrp", "ai", shared_root],
      ["sudo", "chmod", "2775", shared_root],
      ["sudo", "chown", "human", File.join(shared_root, "ddc")],
      ["sudo", "chgrp", "ai", File.join(shared_root, "ddc")],
      ["sudo", "chmod", "2775", File.join(shared_root, "ddc")],
    ]
  end

  test "converge! provisions the DDC dir under an existing shared root" do
    Given "a shared root provisioned before the DDC dir existed"
    executor = converged_identity_executor
    shared_root = Dir.mktmpdir

    When "converging"
    bootstrap(executor, shared_root: shared_root).converge!

    Then "only the DDC dir is provisioned (the root itself is left alone)"
    File.directory?(File.join(shared_root, "ddc"))
    executor.runs == [
      ["sudo", "chown", "human", File.join(shared_root, "ddc")],
      ["sudo", "chgrp", "ai", File.join(shared_root, "ddc")],
      ["sudo", "chmod", "2775", File.join(shared_root, "ddc")],
    ]
  end

  test "converge! migrates ~/.dev artifacts into the shared root, leaving per-user state" do
    Given "a home data dir carrying artifacts and mutable state"
    executor = converged_identity_executor
    home_dev = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(home_dev, "engines", "ue5"))
    FileUtils.mkdir_p(File.join(home_dev, "cache"))
    FileUtils.mkdir_p(File.join(home_dev, "state"))
    shared_root = File.join(Dir.mktmpdir, "dev")

    When "converging"
    bootstrap(executor, shared_root: shared_root, home_dev: home_dev).converge!

    Then "artifacts moved once; state stays per-user"
    File.directory?(File.join(shared_root, "engines", "ue5"))
    File.directory?(File.join(shared_root, "cache"))
    !File.exist?(File.join(home_dev, "engines"))
    File.directory?(File.join(home_dev, "state"))
    !File.exist?(File.join(shared_root, "state"))
  end

  test "migration skips entries the shared root already holds" do
    Given "a shared root that already carries an engines tree"
    executor = converged_identity_executor
    home_dev = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(home_dev, "engines", "stale"))
    shared_root = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(shared_root, "engines", "current"))

    When "converging"
    bootstrap(executor, shared_root: shared_root, home_dev: home_dev).converge!

    Then "the existing tree is untouched and the home copy stays put"
    File.directory?(File.join(shared_root, "engines", "current"))
    !File.exist?(File.join(shared_root, "engines", "stale"))
    File.directory?(File.join(home_dev, "engines", "stale"))
  end

  test "an existing shared root is left alone (no mode churn)" do
    Given "an already-provisioned shared root carrying its DDC dir"
    executor = converged_identity_executor
    shared_root = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(shared_root, "ddc"))

    When "converging"
    bootstrap(executor, shared_root: shared_root).converge!

    Then
    executor.runs.empty?
  end

  # An executor whose identity probes (user, group, memberships, sudoers) all
  # answer converged, so shared-root tests isolate their own step.
  def converged_identity_executor
    RecordedBootstrapExecutor.new(
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
  end

  test "ensure_agent_engine! converges colima, the agent's engine record, and its VM" do
    Given "a host with none of the engine leg present"
    executor = RecordedBootstrapExecutor.new

    When "converging the engine"
    bootstrap(executor).ensure_agent_engine!

    Then "sudo primed; colima installed; record written agent-owned; VM started at defaults"
    executor.runs.fetch(0) == ["sudo", "-v"]
    executor.runs.fetch(1) == ["brew", "install", "colima"]
    executor.runs.fetch(2) ==
      ["sudo", "-H", "-u", "ai-agent", "--", "mkdir", "-p", "/Users/ai-agent/.config/dev"]
    executor.runs.fetch(3).first(6) == ["sudo", "install", "-m", "0644", "-o", "ai-agent"]
    executor.runs.fetch(3).last == "/Users/ai-agent/.config/dev/config.yml"
    executor.runs.fetch(4) == [
      "sudo", "-H", "-u", "ai-agent", "--",
      "colima", "start",
      "--cpu", Dev::ColimaProvisioner::DEFAULT_CPUS.to_s,
      "--memory", Dev::ColimaProvisioner::DEFAULT_MEMORY_GIB.to_s,
      "--vm-type", "vz", "--vz-rosetta",
    ]
    executor.runs.length == 5
  end

  test "ensure_agent_engine! sizes the VM from the repo's resources hint" do
    Given "a resources hint"
    executor = RecordedBootstrapExecutor.new

    When "converging the engine with sizing"
    bootstrap(executor).ensure_agent_engine!(cpus: 12, memory_gib: 24)

    Then
    executor.runs.last == [
      "sudo", "-H", "-u", "ai-agent", "--",
      "colima", "start", "--cpu", "12", "--memory", "24", "--vm-type", "vz", "--vz-rosetta",
    ]
  end

  test "ensure_agent_engine! is a no-op (bar the sudo prime) when the leg is converged" do
    Given "colima installed, record written, VM running"
    executor = RecordedBootstrapExecutor.new(
      probe_results: {
        ["brew", "list", "--formula", "colima"] => true,
        ["sudo", "-n", "-H", "-u", "ai-agent", "--", "colima", "status"] => true,
      },
      capture_results: {
        ["sudo", "cat", "/Users/ai-agent/.config/dev/config.yml"] => "container_engine: colima\n",
      },
    )

    When "converging the engine"
    bootstrap(executor).ensure_agent_engine!

    Then
    executor.runs == [["sudo", "-v"]]
  end

  test "ensure_agent_engine! merges the record into an existing agent config" do
    Given "an agent config carrying another key"
    executor = RecordedBootstrapExecutor.new(
      probe_results: {
        ["brew", "list", "--formula", "colima"] => true,
        ["sudo", "-n", "-H", "-u", "ai-agent", "--", "colima", "status"] => true,
      },
      capture_results: {
        ["sudo", "cat", "/Users/ai-agent/.config/dev/config.yml"] => "plans_repo: d3mlabs/plans\n",
      },
    )
    bs = bootstrap(executor)

    When "converging the engine"
    bs.ensure_agent_engine!

    Then "the staged content keeps the existing key alongside the record"
    staged = bs.agent_config_content("plans_repo: d3mlabs/plans\n")
    staged.include?("plans_repo: d3mlabs/plans")
    staged.include?("container_engine: colima")
  end

  test "after_enroll! grants the _work tree cooperatively and wires the service" do
    Given "a freshly enrolled runner dir"
    executor = RecordedBootstrapExecutor.new
    runner_dir = Dir.mktmpdir
    File.write(File.join(runner_dir, ".service"), "actions.runner.d3mlabs-x.mac\n")
    agents_dir = Dir.mktmpdir
    plist = File.join(agents_dir, "actions.runner.d3mlabs-x.mac.plist")
    work = File.join(runner_dir, "_work")

    When "converging the post-enrollment steps"
    bootstrap(executor, launch_agents_dir: agents_dir).after_enroll!(runner_dir: runner_dir)

    Then "the _work tree gets the cooperative grant; the plist gets the service env; the service restarts"
    File.directory?(work)
    executor.runs.include?(["sudo", "chgrp", "-R", "ai", work])
    executor.runs.include?(["sudo", "chmod", "-R", "g+rwX", work])
    executor.runs.include?(["sudo", "find", work, "-type", "d", "-exec", "chmod", "g+s", "{}", "+"])
    executor.runs.include?(["./svc.sh", "stop", { chdir: runner_dir }])
    executor.runs.include?(["/usr/libexec/PlistBuddy", "-c", "Set :Umask 2", plist])
    executor.runs.include?(
      ["/usr/libexec/PlistBuddy", "-c", "Set :EnvironmentVariables:AI_FLOW_AGENT_USER ai-agent", plist],
    )
    executor.runs.last == ["./svc.sh", "start", { chdir: runner_dir }]
  end

  test "after_enroll! adds plist keys when Set finds none" do
    Given "PlistBuddy Set failing (fresh plist without the keys)"
    executor = RecordedBootstrapExecutor.new(fail_matching: "Set :")
    runner_dir = Dir.mktmpdir
    File.write(File.join(runner_dir, ".service"), "actions.runner.d3mlabs-x.mac\n")
    agents_dir = Dir.mktmpdir
    plist = File.join(agents_dir, "actions.runner.d3mlabs-x.mac.plist")

    When "converging the post-enrollment steps"
    bootstrap(executor, launch_agents_dir: agents_dir).after_enroll!(runner_dir: runner_dir)

    Then "Add fallbacks ran"
    executor.runs.include?(["/usr/libexec/PlistBuddy", "-c", "Add :Umask integer 2", plist])
    executor.runs.include?(
      ["/usr/libexec/PlistBuddy", "-c",
       "Add :EnvironmentVariables:AI_FLOW_AGENT_USER string ai-agent", plist],
    )
  end

  test "after_enroll! raises when the runner dir carries no service record" do
    Given "a runner dir the ceremony never installed a service into"
    executor = RecordedBootstrapExecutor.new
    runner_dir = Dir.mktmpdir

    When "converging the post-enrollment steps"
    bootstrap(executor).after_enroll!(runner_dir: runner_dir)

    Then
    raises Dev::AgentBootstrap::StepFailedError
  end

  test "after_enroll! warns (never raises) when the agent CLI is unresolvable" do
    Given "no cursor-agent on the host"
    executor = RecordedBootstrapExecutor.new
    runner_dir = Dir.mktmpdir
    File.write(File.join(runner_dir, ".service"), "actions.runner.d3mlabs-x.mac\n")
    out = StringIO.new
    bs = Dev::AgentBootstrap.new(
      runner_user: "human", executor: executor, out: out, darwin: true,
      shared_root: Dir.mktmpdir, home_dev: File.join(Dir.mktmpdir, "absent"),
      launch_agents_dir: Dir.mktmpdir,
    )

    When "converging the post-enrollment steps"
    bs.after_enroll!(runner_dir: runner_dir)

    Then "a warning names the missing CLI"
    out.string.include?("cursor-agent")
    out.string.include?("WARNING")
  end

  # The real executor is the true admin-CLI boundary; prove the thin wrapper
  # with cheap real processes instead of mocking Kernel/Open3.
  test "Executor#run reports the child's success, honoring chdir" do
    Given "the real executor"
    executor = Dev::AgentBootstrap::Executor.new

    Expect "success and failure map to true/false, in and out of a chdir"
    executor.run("true")
    !executor.run("false")
    executor.run("true", chdir: Dir.mktmpdir)
  end

  test "Executor#quiet? probes silently and survives a missing binary" do
    Given "the real executor"
    executor = Dev::AgentBootstrap::Executor.new

    Expect
    executor.quiet?("true")
    !executor.quiet?("false")
    !executor.quiet?("dev-test-no-such-binary-#{Process.pid}")
  end

  test "Executor#capture returns stdout on success and empty otherwise" do
    Given "the real executor"
    executor = Dev::AgentBootstrap::Executor.new

    Expect
    executor.capture("echo", "hello") == "hello\n"
    executor.capture("false") == ""
    executor.capture("dev-test-no-such-binary-#{Process.pid}") == ""
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

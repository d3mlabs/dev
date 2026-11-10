# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/agent_bootstrap/linux"
require "support/recorded_bootstrap_executor"
require "fileutils"
require "stringio"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::AgentBootstrap::LinuxTest < Minitest::Test
  SUDOERS_PROBE = ["sudo", "cat", "/etc/sudoers.d/ai-flow-agent"].freeze
  LINUXBREW = "/home/linuxbrew/.linuxbrew/bin/brew"

  # The box's owner lookup: the Linuxbrew prefix is the runner user's
  # (dev#337); nothing else is anyone's.
  RUNNER_OWNS_LINUXBREW = ->(path) { path == "/home/linuxbrew/.linuxbrew" ? "runner" : nil }

  # A Linux adapter over a recorded executor: a tmp data root (its stat is
  # canned by the executor), a tmp systemd dir, no brew, no tap.
  def bootstrap(executor, data_root: Dir.mktmpdir, **kwargs)
    defaults = { data_root: data_root, systemd_dir: Dir.mktmpdir, brew_executable: nil, owner_of: RUNNER_OWNS_LINUXBREW, tap: nil }
    Dev::AgentBootstrap::Linux.new(executor: executor, out: StringIO.new, **defaults.merge(kwargs))
  end

  test "converge! is a no-op when the host is already converged" do
    Given "a host where every probe answers converged"
    data_root = Dir.mktmpdir
    executor = converged_executor(data_root)

    When "converging"
    bootstrap(executor, data_root: data_root).converge!

    Then "nothing was mutated"
    executor.runs.empty?
  end

  test "converge! creates the agent user with useradd — a home, a shell, no groups" do
    Given "a host missing only the agent user"
    data_root = Dir.mktmpdir
    executor = converged_executor(data_root, except_probes: [["id", "-u", "ai-agent"]])

    When "converging"
    bootstrap(executor, data_root: data_root).converge!

    Then
    executor.runs == [["sudo", "useradd", "-m", "-s", "/bin/bash", "ai-agent"]]
  end

  # plans#59: the group is the data root's (`dev`), made by the provisioner
  # on `dev up`; the bootstrap joins the runner user and the agent to it.
  test "converge! creates the dev group when missing and enrolls the runner user and the agent" do
    Given "a host with the agent user but no group memberships"
    data_root = Dir.mktmpdir
    executor = converged_executor(
      data_root,
      except_probes: [["getent", "group", "dev"]],
      except_captures: [["id", "-nG", "runner"], ["id", "-nG", "ai-agent"]],
    )

    When "converging"
    bootstrap(executor, data_root: data_root).converge!

    Then
    executor.runs == [
      ["sudo", "groupadd", "-f", "dev"],
      ["sudo", "usermod", "-aG", "dev", "runner"],
      ["sudo", "usermod", "-aG", "dev", "ai-agent"],
    ]
  end

  test "group membership is read from id -nG" do
    Given
    executor = RecordedBootstrapExecutor.new(capture_results: { ["id", "-nG", "runner"] => "runner docker dev\n" })

    Expect
    bootstrap(executor).group_member?("runner")
    !bootstrap(executor).group_member?("ai-agent")
  end

  # dev#310: the runner user owns the enrollment and its service, so the
  # one-way edge is runner → agent — never the operator's.
  test "the sudoers drop-in grants runner → agent, visudo-staged, root-owned 0440" do
    Given "a host missing only the sudoers drop-in"
    data_root = Dir.mktmpdir
    executor = converged_executor(data_root, except_captures: [SUDOERS_PROBE])
    bs = bootstrap(executor, data_root: data_root)

    When "converging"
    bs.converge!

    Then "the content names the runner user; validate on a staging file, then install"
    bs.sudoers_content.lines.first == "runner ALL=(ai-agent) NOPASSWD:SETENV: ALL\n"
    executor.runs.length == 2
    executor.runs.fetch(0).first(4) == ["sudo", "visudo", "-c", "-f"]
    executor.runs.fetch(1).first(6) == ["sudo", "install", "-m", "0440", "-o", "root"]
    executor.runs.fetch(1).last == "/etc/sudoers.d/ai-flow-agent"
  end

  test "converge! raises and never installs when visudo rejects the drop-in" do
    Given "visudo failing"
    data_root = Dir.mktmpdir
    executor = converged_executor(data_root, except_captures: [SUDOERS_PROBE], fail_matching: "visudo")

    When "converging"
    bootstrap(executor, data_root: data_root).converge!

    Then
    raises Dev::AgentBootstrap::StepFailedError
  end

  test "the data root is asserted shared, never provisioned — #{what}" do
    Given "a data root whose stat answers #{stat.inspect}"
    data_root = Dir.mktmpdir
    executor = RecordedBootstrapExecutor.new(
      probe_results: converged_probes,
      capture_results: converged_captures(data_root).merge(["stat", "-c", "%G %A", data_root] => stat),
    )

    When "converging"
    bootstrap(executor, data_root: data_root).converge!

    Then
    raises Dev::AgentBootstrap::Linux::DataRootNotSharedError
    executor.runs.empty?

    Where
    what                 | stat
    "another group"      | "root drwxrwsr-x\n"
    "not setgid"         | "dev drwxrwxr-x\n"
  end

  test "converge! raises DataRootNotSharedError when the data root is missing" do
    Given "no data root at all"
    missing_root = File.join(Dir.mktmpdir, "absent")
    executor = RecordedBootstrapExecutor.new(probe_results: converged_probes, capture_results: converged_captures(missing_root))

    When "converging"
    bootstrap(executor, data_root: missing_root).converge!

    Then
    raises Dev::AgentBootstrap::Linux::DataRootNotSharedError
  end

  # dev#493: sudo keeps the operator's cwd, which the agent cannot enter;
  # every as-agent command starts from `/`.
  test "converge! has the agent trust the tap as the agent, from /, through the runner's Linuxbrew" do
    Given "a converged host with Linuxbrew and the org tap"
    data_root = Dir.mktmpdir
    executor = converged_executor(data_root, brew_executable: LINUXBREW)
    out = StringIO.new

    When "converging"
    bootstrap(executor, data_root: data_root, out: out, brew_executable: LINUXBREW, tap: org_tap).converge!

    Then
    executor.runs == [[
      "sudo", "-H", "-u", "ai-agent", "--", "env", "-C", "/",
      "env", "HOMEBREW_NO_AUTO_UPDATE=1", LINUXBREW, "trust", "--tap", "d3mlabs/d3mlabs",
    ]]
    out.string.include?(">>> Trusting the tap d3mlabs/d3mlabs for ai-agent")
  end

  test "ensure_agent_engine! refuses — the agent for an image-built repo runs inside the container (plans#61)" do
    Given
    bs = bootstrap(RecordedBootstrapExecutor.new)

    When
    bs.ensure_agent_engine!(cpus: 12, memory_gib: 24, disk_gib: 250)

    Then
    error = raises Dev::AgentBootstrap::Linux::NoAgentEngineError
    error.message.include?("plans#61")
    error.message.include?("root-equivalent")
  end

  test "the engine facts say there is no engine" do
    Given
    bs = bootstrap(RecordedBootstrapExecutor.new)

    Expect
    !bs.engine_converged?
    bs.engine_fact.start_with?("agent engine: ")
    bs.engine_fact.include?("plans#61")
  end

  test "the drop-in carries the service umask and the service env, one Environment= each" do
    Expect
    bootstrap(RecordedBootstrapExecutor.new, agent_user: "ci").drop_in_content(3) == <<~CONF
      [Service]
      UMask=0002
      Environment=AI_FLOW_AGENT_USER=ci
      Environment=AI_FLOW_AGENT_GROUP=dev
      Environment=AI_FLOW_RUNNER_SLOT=3
    CONF
  end

  test "after_enroll! grants the _work tree and installs the unit drop-in around a stop / daemon-reload / start" do
    Given "a freshly enrolled runner dir and an empty systemd dir"
    executor = RecordedBootstrapExecutor.new
    runner_dir = Dir.mktmpdir
    File.write(File.join(runner_dir, ".service"), "actions.runner.d3mlabs-x.box-1.service\n")
    systemd_dir = Dir.mktmpdir
    work = File.join(runner_dir, "_work")
    drop_in = File.join(systemd_dir, "actions.runner.d3mlabs-x.box-1.service.d", "ai-flow-agent.conf")

    When "converging the post-enrollment steps"
    bootstrap(executor, systemd_dir: systemd_dir).after_enroll!(runner_dir: runner_dir, slot: 1)

    Then "the _work grant, then the drop-in sequence under root"
    File.directory?(work)
    executor.runs.first(3) == [
      ["sudo", "chgrp", "-R", "dev", work],
      ["sudo", "chmod", "-R", "g+rwX", work],
      ["sudo", "find", work, "-type", "d", "-exec", "chmod", "g+s", "{}", "+"],
    ]
    executor.runs.fetch(3) == ["sudo", "./svc.sh", "stop", { chdir: runner_dir }]
    executor.runs.fetch(4) == ["sudo", "install", "-d", "-m", "0755", File.dirname(drop_in)]
    executor.runs.fetch(5).first(4) == ["sudo", "install", "-m", "0644"]
    executor.runs.fetch(5).last == drop_in
    executor.runs.fetch(6) == ["sudo", "systemctl", "daemon-reload"]
    executor.runs.fetch(7) == ["sudo", "./svc.sh", "start", { chdir: runner_dir }]
    executor.runs.length == 8
  end

  test "after_enroll! appends .service to a bare unit record" do
    Given "a .service record without the suffix"
    executor = RecordedBootstrapExecutor.new
    runner_dir = Dir.mktmpdir
    File.write(File.join(runner_dir, ".service"), "actions.runner.d3mlabs-x.box\n")
    systemd_dir = Dir.mktmpdir

    When "converging the post-enrollment steps"
    bootstrap(executor, systemd_dir: systemd_dir).after_enroll!(runner_dir: runner_dir, slot: 1)

    Then
    executor.runs.include?(["sudo", "install", "-d", "-m", "0755", File.join(systemd_dir, "actions.runner.d3mlabs-x.box.service.d")])
  end

  test "after_enroll! leaves a drop-in already saying this alone — the service is not bounced" do
    Given "a drop-in matching the desired content"
    executor = RecordedBootstrapExecutor.new
    runner_dir = Dir.mktmpdir
    File.write(File.join(runner_dir, ".service"), "actions.runner.d3mlabs-x.box-2.service\n")
    systemd_dir = Dir.mktmpdir
    bs = bootstrap(executor, systemd_dir: systemd_dir)
    drop_in_dir = File.join(systemd_dir, "actions.runner.d3mlabs-x.box-2.service.d")
    FileUtils.mkdir_p(drop_in_dir)
    File.write(File.join(drop_in_dir, "ai-flow-agent.conf"), bs.drop_in_content(2))

    When "converging the post-enrollment steps"
    bs.after_enroll!(runner_dir: runner_dir, slot: 2)

    Then "only the _work grant ran"
    executor.runs.length == 3
    executor.runs.none? { |argv| argv.include?("systemctl") }
  end

  test "after_enroll! rewrites a drop-in that drifted (another slot)" do
    Given "a drop-in recorded for slot 1 while this enrollment is slot 2"
    executor = RecordedBootstrapExecutor.new
    runner_dir = Dir.mktmpdir
    File.write(File.join(runner_dir, ".service"), "actions.runner.d3mlabs-x.box-2.service\n")
    systemd_dir = Dir.mktmpdir
    bs = bootstrap(executor, systemd_dir: systemd_dir)
    drop_in_dir = File.join(systemd_dir, "actions.runner.d3mlabs-x.box-2.service.d")
    FileUtils.mkdir_p(drop_in_dir)
    File.write(File.join(drop_in_dir, "ai-flow-agent.conf"), bs.drop_in_content(1))

    When "converging the post-enrollment steps"
    bs.after_enroll!(runner_dir: runner_dir, slot: 2)

    Then
    executor.runs.include?(["sudo", "systemctl", "daemon-reload"])
  end

  test "after_enroll! raises when the runner dir carries no service record" do
    Given
    executor = RecordedBootstrapExecutor.new
    runner_dir = Dir.mktmpdir

    When
    bootstrap(executor).after_enroll!(runner_dir: runner_dir, slot: 1)

    Then
    raises Dev::AgentBootstrap::StepFailedError
  end

  test "after_enroll! warns (never raises) when the agent CLI is unresolvable" do
    Given "no cursor-agent on the host"
    executor = RecordedBootstrapExecutor.new
    runner_dir = Dir.mktmpdir
    File.write(File.join(runner_dir, ".service"), "actions.runner.d3mlabs-x.box.service\n")
    out = StringIO.new

    When
    bootstrap(executor, out: out).after_enroll!(runner_dir: runner_dir, slot: 1)

    Then
    out.string.include?("WARNING")
    out.string.include?("cursor-agent")
  end

  def org_tap = Dev::TapTrust::Tap.new(user: "d3mlabs", repo: "d3mlabs")

  # Probes that answer converged: the agent user exists, the group exists.
  def converged_probes
    { ["id", "-u", "ai-agent"] => true, ["getent", "group", "dev"] => true }
  end

  # Captures that answer converged: both identities in the group, the
  # sudoers drop-in as written for the given brew, the data root shared.
  def converged_captures(data_root, **bootstrap_kwargs)
    {
      ["id", "-nG", "runner"] => "runner docker dev\n",
      ["id", "-nG", "ai-agent"] => "ai-agent dev\n",
      SUDOERS_PROBE => bootstrap(RecordedBootstrapExecutor.new, **bootstrap_kwargs).sudoers_content,
      ["stat", "-c", "%G %A", data_root] => "dev drwxrwsr-x\n",
    }
  end

  # A fully converged host, minus the probes/captures named — so each test
  # isolates one step.
  #
  # @param data_root [String] the real tmp dir the bootstrap under test uses
  # @param except_probes [Array<Array<String>>] probes to answer "absent"
  # @param except_captures [Array<Array<String>>] captures to answer ""
  # @param fail_matching [String, nil] run() fails when the argv mentions this token
  # @param bootstrap_kwargs [Hash] what shapes the drop-in on "disk" (`brew_executable:`)
  def converged_executor(data_root, except_probes: [], except_captures: [], fail_matching: nil, **bootstrap_kwargs)
    RecordedBootstrapExecutor.new(
      fail_matching: fail_matching,
      probe_results: converged_probes.except(*except_probes),
      capture_results: converged_captures(data_root, **bootstrap_kwargs).except(*except_captures),
    )
  end
end

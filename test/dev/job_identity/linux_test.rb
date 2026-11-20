# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/job_identity/linux"
require "support/recorded_bootstrap_executor"
require "fileutils"
require "support/recording_ui"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::JobIdentity::LinuxTest < Minitest::Test
  SUDOERS_PROBE = ["sudo", "cat", "/etc/sudoers.d/ai-flow-agent"].freeze
  LINUXBREW = "/home/linuxbrew/.linuxbrew/bin/brew"
  LINUXBREW_LOCKS = "/home/linuxbrew/.linuxbrew/var/homebrew/locks"

  # The box's owner lookup: the Linuxbrew prefix is the runner user's
  # (dev#337); nothing else is anyone's.
  RUNNER_OWNS_LINUXBREW = ->(path) { path == "/home/linuxbrew/.linuxbrew" ? "runner" : nil }

  # A Linux adapter over a recorded executor for the `ai-agent` identity:
  # a tmp data root (its stat is canned by the executor), a tmp systemd
  # dir, no brew, no tap.
  def bootstrap(executor, data_root: Dir.mktmpdir, **kwargs)
    defaults = { user: "ai-agent", data_root: data_root, systemd_dir: Dir.mktmpdir, brew_executable: nil, owner_of: RUNNER_OWNS_LINUXBREW, tap: nil }
    Dev::JobIdentity::Linux.new(executor: executor, ui: RecordingUi.new, **defaults.merge(kwargs))
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

  test "converge! creates the user with useradd — a home, a shell, no groups" do
    Given "a host missing only the user"
    data_root = Dir.mktmpdir
    executor = converged_executor(data_root, except_probes: [["id", "-u", "ai-agent"]])

    ui = RecordingUi.new

    When "converging"
    bootstrap(executor, data_root: data_root, ui: ui).converge!

    Then
    executor.runs == [["sudo", "useradd", "-m", "-s", "/bin/bash", "ai-agent"]]
    ui.rows == [[:step, "Creating the ai-agent user (non-admin)", 0]]
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
    raises Dev::JobIdentity::StepFailedError
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
    raises Dev::JobIdentity::Linux::DataRootNotSharedError
    executor.runs.empty?

    Where
    what                 | stat
    "another group"      | "root drwxrwsr-x\n"
    "not setgid"         | "dev drwxrwxr-x\n"
  end

  test "converge! raises DataRootNotSharedError when the data root is missing" do
    Given "no data root at all — stat says nothing of it"
    missing_root = File.join(Dir.mktmpdir, "absent")
    executor = converged_executor(missing_root, except_captures: [["stat", "-c", "%G %A", missing_root]])

    When "converging"
    bootstrap(executor, data_root: missing_root).converge!

    Then
    raises Dev::JobIdentity::Linux::DataRootNotSharedError
  end

  # dev#493: sudo keeps the operator's cwd, which the agent cannot enter;
  # every as-agent command starts from `/`.
  test "converge! has the agent trust the tap as the agent, from /, through the runner's Linuxbrew" do
    Given "a converged host with Linuxbrew (its lock dir cooperative) and the org tap"
    data_root = Dir.mktmpdir
    executor = converged_executor(data_root, brew_executable: LINUXBREW)
    ui = RecordingUi.new

    When "converging"
    bootstrap(executor, data_root: data_root, ui: ui, brew_executable: LINUXBREW, tap: org_tap).converge!

    Then
    executor.runs == [[
      "sudo", "-H", "-u", "ai-agent", "--", "env", "-C", "/",
      "env", "HOMEBREW_NO_AUTO_UPDATE=1", LINUXBREW, "trust", "--tap", "d3mlabs/d3mlabs",
    ]]
    ui.rows == [[:step, "Trusting the tap d3mlabs/d3mlabs for ai-agent (brew loads nothing from a tap its user has not trusted)", 0]]
  end

  # dev#558: the box's first register — `brew trust` as ai-agent died on
  # `var/homebrew/locks/packages.x86_64_linux.jws.json.download.lock`, the
  # runner-owned prefix's lock dir; the lock dir is granted before the
  # agent's first brew, in the Linux stat dialect.
  test "converge! grants the group the runner's Linuxbrew lock dir before the tap trust" do
    Given "a converged host whose Linuxbrew lock dir is the runner's alone"
    data_root = Dir.mktmpdir
    executor = converged_executor(data_root, except_captures: [["stat", "-c", "%G %A", LINUXBREW_LOCKS]], brew_executable: LINUXBREW)

    When "converging"
    bootstrap(executor, data_root: data_root, brew_executable: LINUXBREW, tap: org_tap).converge!

    Then
    executor.runs.first(4) == [
      ["sudo", "mkdir", "-p", LINUXBREW_LOCKS],
      ["sudo", "chgrp", "-R", "dev", LINUXBREW_LOCKS],
      ["sudo", "chmod", "-R", "g+rwX", LINUXBREW_LOCKS],
      ["sudo", "chmod", "g+s", LINUXBREW_LOCKS],
    ]
    executor.runs.fetch(4).include?("trust")
  end

  # dev#569: the box's first register wrote `ai-agent ALL=(runner)
  # NOPASSWD:SETENV: …/bin/brew` — brew as a docker-group user, root in two
  # hops. A drop-in still carrying it differs from the desired content and
  # is rewritten without it; nothing else on the host is touched.
  test "converge! rewrites a drop-in still carrying the retired brew edge, with nothing else to do" do
    Given "a converged host whose drop-in grants the agent the runner's Linuxbrew"
    data_root = Dir.mktmpdir
    stale = "runner ALL=(ai-agent) NOPASSWD:SETENV: ALL\n" \
      "Defaults>ai-agent env_reset, umask=0002, umask_override\n" \
      "ai-agent ALL=(runner) NOPASSWD:SETENV: #{LINUXBREW}\n"
    executor = RecordedBootstrapExecutor.new(
      probe_results: converged_probes,
      capture_results: converged_captures(data_root, brew_executable: LINUXBREW).merge(SUDOERS_PROBE => stale),
    )
    ui = RecordingUi.new

    When "converging"
    bootstrap(executor, data_root: data_root, ui: ui, brew_executable: LINUXBREW).converge!

    Then "the drop-in is re-staged and re-installed — the only mutation"
    ui.rows == [[:step, "Installing the sudoers edge (/etc/sudoers.d/ai-flow-agent)", 0]]
    executor.runs.length == 2
    executor.runs.fetch(0).first(4) == ["sudo", "visudo", "-c", "-f"]
    executor.runs.fetch(1).last == "/etc/sudoers.d/ai-flow-agent"
  end

  # The lock dir is the agent's concern on any prefix it does not own —
  # the fact the grant was always about, no longer read off the edge.
  test "the runner's Linuxbrew is a shared prefix: its lock dir is the agent's concern, the agent's own prefix is not" do
    Expect
    bootstrap(RecordedBootstrapExecutor.new, brew_executable: LINUXBREW).shared_brew_prefix == "/home/linuxbrew/.linuxbrew"
    bootstrap(RecordedBootstrapExecutor.new, brew_executable: LINUXBREW).brew_locks_dir == LINUXBREW_LOCKS
    bootstrap(RecordedBootstrapExecutor.new, brew_executable: LINUXBREW, owner_of: ->(_path) { "ai-agent" }).brew_locks_dir.nil?
  end

  test "ensure_engine! refuses — the agent for an image-built repo runs inside the container (plans#61)" do
    Given
    bs = bootstrap(RecordedBootstrapExecutor.new)

    When
    bs.ensure_engine!(cpus: 12, memory_gib: 24, disk_gib: 250)

    Then
    error = raises Dev::JobIdentity::Linux::NoEngineError
    error.message.include?("inside the project's container")
    error.message.include?("root-equivalent")
  end

  test "the engine facts say there is no engine" do
    Given
    bs = bootstrap(RecordedBootstrapExecutor.new)

    Expect
    !bs.engine_converged?
    bs.engine_fact.start_with?("engine: ")
    bs.engine_fact.include?("inside the project's container")
  end

  test "the drop-in carries the service umask and the service env, one Environment= each" do
    Expect
    bootstrap(RecordedBootstrapExecutor.new, user: "ci").drop_in_content(3) == <<~CONF
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
    ui = RecordingUi.new

    When "converging the post-enrollment steps"
    bootstrap(executor, systemd_dir: systemd_dir, ui: ui).after_enroll!(runner_dir: runner_dir, slot: 1)

    Then "the _work tree made under root as the runner's own (its dir is the runner's, not the operator's), then the grant, then the drop-in sequence — a step each, and nothing about any agent CLI: what the identity needs beyond this is the declaring project's"
    ui.rows == [
      [:step, "Granting the dev group cooperative access to #{work}", 0],
      [:step, "Writing UMask 0002 + AI_FLOW_AGENT_USER=ai-agent + AI_FLOW_AGENT_GROUP=dev + AI_FLOW_RUNNER_SLOT=1 into #{drop_in}", 0],
    ]
    !File.directory?(work)
    executor.runs.first(4) == [
      ["sudo", "install", "-d", "-o", "runner", "-g", "dev", "-m", "2775", work],
      ["sudo", "chgrp", "-R", "dev", work],
      ["sudo", "chmod", "-R", "g+rwX", work],
      ["sudo", "find", work, "-type", "d", "-exec", "chmod", "g+s", "{}", "+"],
    ]
    executor.runs.fetch(4) == ["sudo", "./svc.sh", "stop", { chdir: runner_dir }]
    executor.runs.fetch(5) == ["sudo", "install", "-d", "-m", "0755", File.dirname(drop_in)]
    executor.runs.fetch(6).first(4) == ["sudo", "install", "-m", "0644"]
    executor.runs.fetch(6).last == drop_in
    executor.runs.fetch(7) == ["sudo", "systemctl", "daemon-reload"]
    executor.runs.fetch(8) == ["sudo", "./svc.sh", "start", { chdir: runner_dir }]
    executor.runs.length == 9
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
    executor.runs.length == 4
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
    raises Dev::JobIdentity::StepFailedError
  end

  def org_tap
    Dev::TapTrust::Tap.new(user: "d3mlabs", repo: "d3mlabs")
  end

  # Probes that answer converged: the user exists, the group exists.
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
      ["stat", "-c", "%G %A", LINUXBREW_LOCKS] => "dev drwxrwsr-x\n",
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

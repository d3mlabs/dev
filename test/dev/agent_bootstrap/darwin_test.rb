# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/agent_bootstrap/darwin"
require "support/recorded_bootstrap_executor"
require "etc"
require "fileutils"
require "stringio"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::AgentBootstrap::DarwinTest < Minitest::Test
  # `colima list -j` answer for a running VM already at the agent's hint
  # (12 cpus / 24 GiB), so the provisioner has nothing to do.
  RUNNING_AGENT_VM_JSON = '{"name":"default","status":"Running","arch":"aarch64","cpus":12,' \
    '"memory":25769803776,"disk":107374182400,"runtime":"docker"}'

  # The sudoers drop-in a bootstrap over the same brew writes, so the
  # probe never drifts from the desire.
  SUDOERS_PROBE = ["sudo", "cat", "/etc/sudoers.d/ai-flow-agent"].freeze

  # Filesystem-facing params always point at tmp paths: an already-provisioned
  # shared root (DDC dir included) and no ~/.dev to migrate; and no
  # deployment tap (the host's Settings never decide a test), so
  # identity-step tests stay focused.
  def bootstrap(executor, **kwargs)
    provisioned_root = Dir.mktmpdir.tap { |root| FileUtils.mkdir_p(File.join(root, "ddc")) }
    defaults = {
      data_root: provisioned_root, home_dev: File.join(Dir.mktmpdir, "absent-home-dev"),
      launch_agents_dir: Dir.mktmpdir, brew_executable: nil, tap: nil,
    }
    Dev::AgentBootstrap::Darwin.new(runner_user: "human", executor: executor, out: StringIO.new, **defaults.merge(kwargs))
  end

  test "converge! is a no-op when the host is already converged" do
    Given "a host where every probe answers converged"
    executor = converged_identity_executor

    When "converging"
    bootstrap(executor).converge!

    Then "nothing was mutated"
    executor.runs.empty?
  end

  test "converge! creates the hidden non-admin agent user with its own home" do
    Given "a host missing only the agent user"
    executor = RecordedBootstrapExecutor.new(
      probe_results: {
        ["dseditgroup", "-o", "read", "dev"] => true,
        ["dseditgroup", "-o", "checkmember", "-m", "human", "dev"] => true,
        ["dseditgroup", "-o", "checkmember", "-m", "ai-agent", "dev"] => true,
      },
      capture_results: { SUDOERS_PROBE => sudoers_content },
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

  # plans#59: the group is the data root's (`dev`), the one name every
  # host uses — the Mac's `ai` is the legacy name, re-grouped below.
  test "converge! creates the dev group and enrolls both identities" do
    Given "a host missing the group"
    executor = RecordedBootstrapExecutor.new(
      probe_results: { ["id", "-u", "ai-agent"] => true },
      capture_results: { SUDOERS_PROBE => sudoers_content },
    )

    When "converging"
    bootstrap(executor).converge!

    Then
    executor.runs == [
      ["sudo", "dseditgroup", "-o", "create", "dev"],
      ["sudo", "dseditgroup", "-o", "edit", "-a", "human", "-t", "user", "dev"],
      ["sudo", "dseditgroup", "-o", "edit", "-a", "ai-agent", "-t", "user", "dev"],
    ]
  end

  test "converge! writes the sudoers drop-in only after visudo validates it" do
    Given "a host missing only the sudoers drop-in"
    executor = RecordedBootstrapExecutor.new(probe_results: identity_probes)

    When "converging"
    bootstrap(executor).converge!

    Then "validate on a staging file, then install root-owned 0440"
    executor.runs.length == 2
    executor.runs.fetch(0).first(4) == ["sudo", "visudo", "-c", "-f"]
    executor.runs.fetch(1).first(6) == ["sudo", "install", "-m", "0440", "-o", "root"]
    executor.runs.fetch(1).last == "/etc/sudoers.d/ai-flow-agent"
  end

  test "converge! raises and never installs when visudo rejects the drop-in" do
    Given "visudo failing"
    executor = RecordedBootstrapExecutor.new(fail_matching: "visudo", probe_results: identity_probes)

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
    bootstrap(executor, data_root: shared_root).converge!

    Then "root and DDC dir exist, human-owned, group dev, setgid group-writable — and nothing is re-grouped"
    File.directory?(shared_root)
    File.directory?(File.join(shared_root, "ddc"))
    executor.runs == [
      ["sudo", "chown", "human", shared_root],
      ["sudo", "chgrp", "dev", shared_root],
      ["sudo", "chmod", "2775", shared_root],
      ["sudo", "chown", "human", File.join(shared_root, "ddc")],
      ["sudo", "chgrp", "dev", File.join(shared_root, "ddc")],
      ["sudo", "chmod", "2775", File.join(shared_root, "ddc")],
    ]
  end

  test "converge! provisions the DDC dir under an existing shared root" do
    Given "a shared root provisioned before the DDC dir existed"
    executor = converged_identity_executor
    shared_root = Dir.mktmpdir

    When "converging"
    bootstrap(executor, data_root: shared_root).converge!

    Then "only the DDC dir is provisioned (the root itself is left alone)"
    File.directory?(File.join(shared_root, "ddc"))
    executor.runs == [
      ["sudo", "chown", "human", File.join(shared_root, "ddc")],
      ["sudo", "chgrp", "dev", File.join(shared_root, "ddc")],
      ["sudo", "chmod", "2775", File.join(shared_root, "ddc")],
    ]
  end

  # plans#59: a Mac bootstrapped before the one group name has its root
  # in `ai`; the next register moves the tree to `dev` — once, `-h` so
  # symlinks are re-grouped and never followed.
  test "converge! re-groups a shared root still in the legacy ai group, tree and all" do
    Given "a converged host whose shared root stats as group ai"
    shared_root = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(shared_root, "ddc"))
    executor = converged_identity_executor(capture_results: { ["stat", "-f", "%Sg %Sp", shared_root] => "ai drwxrwsr-x\n" })
    out = StringIO.new

    When "converging"
    bootstrap(executor, data_root: shared_root, out: out).converge!

    Then "one recursive chgrp, announced; modes untouched"
    executor.runs == [["sudo", "chgrp", "-Rh", "dev", shared_root]]
    out.string.include?("Re-grouping #{shared_root} from ai to dev")
  end

  test "converge! leaves a shared root in any other group alone (drift is status's to report)" do
    Given "a converged host whose shared root stats as group staff"
    shared_root = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(shared_root, "ddc"))
    executor = converged_identity_executor(capture_results: { ["stat", "-f", "%Sg %Sp", shared_root] => "staff drwxr-xr-x\n" })

    When "converging"
    bootstrap(executor, data_root: shared_root).converge!

    Then
    executor.runs.empty?
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
    bootstrap(executor, data_root: shared_root, home_dev: home_dev).converge!

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
    bootstrap(executor, data_root: shared_root, home_dev: home_dev).converge!

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
    bootstrap(executor, data_root: shared_root).converge!

    Then
    executor.runs.empty?
  end

  # dev#374: the agent is a different brew user from the operator, and
  # Homebrew 7's tap trust is per user — without this step every tap
  # formula `dev deps` touched as the agent was refused, and a /build pass
  # ran `brew trust` itself to get on.
  test "converge! has the agent user trust the deployment's tap — as the agent, through sudo, the brew dev found" do
    Given "a converged host with brew and the org tap"
    brew = brew_in(Dir.mktmpdir)
    executor = converged_identity_executor(brew_executable: brew)
    out = StringIO.new

    When "converging"
    bootstrap(executor, out: out, brew_executable: brew, tap: org_tap).converge!

    Then "the one step is brew trust as the agent, and it is announced"
    executor.runs == [["sudo", "-H", "-u", "ai-agent", "--", "env", "HOMEBREW_NO_AUTO_UPDATE=1", brew, "trust", "--tap", "d3mlabs/d3mlabs"]]
    out.string.include?(">>> Trusting the tap d3mlabs/d3mlabs for ai-agent")
    !out.string.include?("warning")
  end

  test "converge! issues no trust step without brew on the host" do
    Given "a converged host without brew, and the org tap"
    executor = converged_identity_executor

    When "converging"
    bootstrap(executor, brew_executable: nil, tap: org_tap).converge!

    Then
    executor.runs.empty?
  end

  test "a brew without `trust` (nonzero exit) is a warning naming the by-hand command, not StepFailedError" do
    Given "a converged host whose brew predates `brew trust`"
    brew = brew_in(Dir.mktmpdir)
    executor = converged_identity_executor(fail_matching: "trust", brew_executable: brew)
    out = StringIO.new

    When "converging"
    bootstrap(executor, out: out, brew_executable: brew, tap: org_tap).converge!

    Then "it ran, it was refused, and register went on"
    executor.runs.count(&trusts) == 1
    out.string.include?("dev: warning: could not trust the tap d3mlabs/d3mlabs for ai-agent")
    out.string.include?("`sudo -iu ai-agent brew trust --tap d3mlabs/d3mlabs`")
  end

  # A lambda, not a block: a one-parameter block is emitted as |argv,| by
  # the transform (rspockframework/ast-transform#21) and destructures an argv.
  def trusts = ->(argv) { argv.include?("trust") }
  def org_tap = Dev::TapTrust::Tap.new(user: "d3mlabs", repo: "d3mlabs")

  # A brew binary at <prefix>/bin/brew, as BREW_LOCATIONS discovers one.
  def brew_in(prefix)
    File.join(prefix, "bin", "brew").tap do |brew|
      FileUtils.mkdir_p(File.dirname(brew))
      File.write(brew, "")
    end
  end

  # The identity probes (user, group, memberships) all answering converged.
  def identity_probes
    {
      ["id", "-u", "ai-agent"] => true,
      ["dseditgroup", "-o", "read", "dev"] => true,
      ["dseditgroup", "-o", "checkmember", "-m", "human", "dev"] => true,
      ["dseditgroup", "-o", "checkmember", "-m", "ai-agent", "dev"] => true,
    }
  end

  # The drop-in a bootstrap with the given brew writes.
  def sudoers_content(**bootstrap_kwargs)
    bootstrap(RecordedBootstrapExecutor.new, **bootstrap_kwargs).sudoers_content
  end

  # An executor whose identity probes (user, group, memberships, sudoers) all
  # answer converged, so shared-root and trust tests isolate their own step.
  # The sudoers drop-in on "disk" is the one a bootstrap with the same brew
  # would write, so the brew edge never drifts between probe and desire.
  #
  # @param fail_matching [String, nil] run() fails when the argv mentions this token
  # @param capture_results [Hash] further canned captures (a root's stat)
  # @param bootstrap_kwargs [Hash] what the bootstrap under test is built
  #   with that shapes the drop-in (`brew_executable:`)
  def converged_identity_executor(fail_matching: nil, capture_results: {}, **bootstrap_kwargs)
    RecordedBootstrapExecutor.new(
      fail_matching: fail_matching,
      probe_results: identity_probes,
      capture_results: { SUDOERS_PROBE => sudoers_content(**bootstrap_kwargs) }.merge(capture_results),
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
    bootstrap(executor).ensure_agent_engine!(cpus: 12, memory_gib: 24, disk_gib: 250)

    Then
    executor.runs.last == [
      "sudo", "-H", "-u", "ai-agent", "--",
      "colima", "start", "--cpu", "12", "--memory", "24", "--disk", "250", "--vm-type", "vz", "--vz-rosetta",
    ]
  end

  test "ensure_agent_engine! is a no-op (bar the sudo prime) when the leg is converged" do
    Given "colima installed, record written, VM running"
    executor = RecordedBootstrapExecutor.new(
      probe_results: { ["brew", "list", "--formula", "colima"] => true },
      capture_results: {
        ["sudo", "-n", "-H", "-u", "ai-agent", "--", "colima", "list", "-j"] => RUNNING_AGENT_VM_JSON,
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
      probe_results: { ["brew", "list", "--formula", "colima"] => true },
      capture_results: {
        ["sudo", "-n", "-H", "-u", "ai-agent", "--", "colima", "list", "-j"] => RUNNING_AGENT_VM_JSON,
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

  test "the engine facts are colima's" do
    Given "a host with colima installed"
    executor = RecordedBootstrapExecutor.new(probe_results: { ["brew", "list", "--formula", "colima"] => true })

    Expect
    bootstrap(executor).engine_converged?
    bootstrap(executor).engine_fact == "colima installed (container engine)"
    !bootstrap(RecordedBootstrapExecutor.new).engine_converged?
  end

  test "group membership is dseditgroup's answer" do
    Given
    executor = RecordedBootstrapExecutor.new(probe_results: { ["dseditgroup", "-o", "checkmember", "-m", "human", "dev"] => true })

    Expect
    bootstrap(executor).group_member?("human")
    !bootstrap(executor).group_member?("ai-agent")
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
    bootstrap(executor, launch_agents_dir: agents_dir).after_enroll!(runner_dir: runner_dir, slot: 1)

    Then "the _work tree gets the cooperative grant in group dev; the plist gets the service env; the service restarts"
    File.directory?(work)
    executor.runs.include?(["sudo", "chgrp", "-R", "dev", work])
    executor.runs.include?(["sudo", "chmod", "-R", "g+rwX", work])
    executor.runs.include?(["sudo", "find", work, "-type", "d", "-exec", "chmod", "g+s", "{}", "+"])
    executor.runs.include?(["./svc.sh", "stop", { chdir: runner_dir }])
    executor.runs.include?(["/usr/libexec/PlistBuddy", "-c", "Set :Umask 2", plist])
    executor.runs.include?(["/usr/libexec/PlistBuddy", "-c", "Set :EnvironmentVariables:AI_FLOW_AGENT_USER ai-agent", plist])
    executor.runs.include?(["/usr/libexec/PlistBuddy", "-c", "Set :EnvironmentVariables:AI_FLOW_AGENT_GROUP dev", plist])
    executor.runs.include?(["/usr/libexec/PlistBuddy", "-c", "Set :EnvironmentVariables:AI_FLOW_RUNNER_SLOT 1", plist])
    executor.runs.last == ["./svc.sh", "start", { chdir: runner_dir }]
  end

  # ai-flow#116 / dev#485: ai-flow keys per-slot state (the agent's gem
  # home, a persistent workspace) by the slot number; only dev knows which
  # enrollment is which slot, so dev records it where it records the agent
  # user — this slot's service env.
  test "after_enroll! writes the slot number into that slot's service env" do
    Given "slot 3's freshly enrolled runner dir"
    executor = RecordedBootstrapExecutor.new
    runner_dir = Dir.mktmpdir
    File.write(File.join(runner_dir, ".service"), "actions.runner.d3mlabs-x.mac-3\n")
    agents_dir = Dir.mktmpdir
    plist = File.join(agents_dir, "actions.runner.d3mlabs-x.mac-3.plist")

    When "converging the post-enrollment steps for slot 3"
    bootstrap(executor, launch_agents_dir: agents_dir).after_enroll!(runner_dir: runner_dir, slot: 3)

    Then "the plist carries AI_FLOW_RUNNER_SLOT=3, between the service stop and start"
    stop = executor.runs.index(["./svc.sh", "stop", { chdir: runner_dir }])
    slot = executor.runs.index(["/usr/libexec/PlistBuddy", "-c", "Set :EnvironmentVariables:AI_FLOW_RUNNER_SLOT 3", plist])
    start = executor.runs.index(["./svc.sh", "start", { chdir: runner_dir }])
    !stop.nil? && !slot.nil? && !start.nil?
    stop < slot && slot < start
  end

  test "after_enroll! uses the .service record verbatim when it is a plist path (macOS svc.sh shape)" do
    Given "a runner dir whose .service records the full plist path, as macOS svc.sh writes it"
    executor = RecordedBootstrapExecutor.new
    runner_dir = Dir.mktmpdir
    agents_dir = Dir.mktmpdir
    plist = File.join(agents_dir, "actions.runner.d3mlabs.mac.plist")
    File.write(File.join(runner_dir, ".service"), "#{plist}\n")

    When "converging the post-enrollment steps"
    bootstrap(executor, launch_agents_dir: agents_dir).after_enroll!(runner_dir: runner_dir, slot: 1)

    Then "PlistBuddy targets the recorded path, not a re-joined one"
    executor.runs.include?(["/usr/libexec/PlistBuddy", "-c", "Set :Umask 2", plist])
    executor.runs.include?(["/usr/libexec/PlistBuddy", "-c", "Set :EnvironmentVariables:AI_FLOW_AGENT_USER ai-agent", plist])
  end

  test "after_enroll! adds plist keys when Set finds none" do
    Given "PlistBuddy Set failing (fresh plist without the keys)"
    executor = RecordedBootstrapExecutor.new(fail_matching: "Set :")
    runner_dir = Dir.mktmpdir
    File.write(File.join(runner_dir, ".service"), "actions.runner.d3mlabs-x.mac\n")
    agents_dir = Dir.mktmpdir
    plist = File.join(agents_dir, "actions.runner.d3mlabs-x.mac.plist")

    When "converging the post-enrollment steps"
    bootstrap(executor, launch_agents_dir: agents_dir).after_enroll!(runner_dir: runner_dir, slot: 1)

    Then "Add fallbacks ran"
    executor.runs.include?(["/usr/libexec/PlistBuddy", "-c", "Add :Umask integer 2", plist])
    executor.runs.include?(["/usr/libexec/PlistBuddy", "-c", "Add :EnvironmentVariables:AI_FLOW_AGENT_USER string ai-agent", plist])
    executor.runs.include?(["/usr/libexec/PlistBuddy", "-c", "Add :EnvironmentVariables:AI_FLOW_AGENT_GROUP string dev", plist])
    executor.runs.include?(["/usr/libexec/PlistBuddy", "-c", "Add :EnvironmentVariables:AI_FLOW_RUNNER_SLOT string 1", plist])
  end

  test "after_enroll! raises when the runner dir carries no service record" do
    Given "a runner dir the ceremony never installed a service into"
    executor = RecordedBootstrapExecutor.new
    runner_dir = Dir.mktmpdir

    When "converging the post-enrollment steps"
    bootstrap(executor).after_enroll!(runner_dir: runner_dir, slot: 1)

    Then
    raises Dev::AgentBootstrap::StepFailedError
  end

  test "after_enroll! warns (never raises) when the agent CLI is unresolvable" do
    Given "no cursor-agent on the host"
    executor = RecordedBootstrapExecutor.new
    runner_dir = Dir.mktmpdir
    File.write(File.join(runner_dir, ".service"), "actions.runner.d3mlabs-x.mac\n")
    out = StringIO.new

    When "converging the post-enrollment steps"
    bootstrap(executor, out: out).after_enroll!(runner_dir: runner_dir, slot: 1)

    Then "a warning names the missing CLI"
    out.string.include?("cursor-agent")
    out.string.include?("WARNING")
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

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/job_identity"
require "dev/job_identity/darwin"
require "dev/job_identity/linux"
require "support/recorded_bootstrap_executor"
require "etc"
require "tmpdir"

# The job identity's own facts — what both adapters share: the
# composition root, the sudoers drop-in, the brew edge's absence, the
# service env, the executor boundary. The platform steps are each
# adapter's test (job_identity/*_test.rb).
transform!(RSpock::AST::Transformation)
class Dev::JobIdentityTest < Minitest::Test
  # The owner lookup the box answers: the Linuxbrew prefix is the runner
  # user's (dev#337), nothing else is anyone's.
  RUNNER_OWNS_LINUXBREW = ->(path) { path == "/home/linuxbrew/.linuxbrew" ? "runner" : nil }

  # The adapters over a recorded executor, with no tap and tmp paths —
  # class methods so Where tables (evaluated in class scope) can build them.
  class << self
    def darwin(**kwargs)
      Dev::JobIdentity::Darwin.new(
        user: "ai-agent", runner_user: "human", executor: RecordedBootstrapExecutor.new, tap: nil,
        data_root: Dir.mktmpdir, home_dev: File.join(Dir.mktmpdir, "absent"), brew_executable: nil, **kwargs
      )
    end

    def linux(**kwargs)
      Dev::JobIdentity::Linux.new(
        user: "ai-agent", executor: RecordedBootstrapExecutor.new, tap: nil,
        data_root: Dir.mktmpdir, systemd_dir: Dir.mktmpdir, brew_executable: nil, **kwargs
      )
    end
  end

  # --- the composition root -----------------------------------------------------

  test "for_host builds the #{host_os} adapter for the user, spawned from the runner user given" do
    When
    identity = Dev::JobIdentity.for_host(user: "ci", runner_user: "runner", executor: RecordedBootstrapExecutor.new, host_os: host_os)

    Then
    identity.is_a?(adapter)
    identity.user == "ci"
    identity.runner_user == "runner"

    Where
    host_os  | adapter
    "darwin" | Dev::JobIdentity::Darwin
    "linux"  | Dev::JobIdentity::Linux
  end

  test "for_host without a runner user takes the platform's: the rule's default on Linux, the operator on a Mac" do
    Expect
    Dev::JobIdentity.for_host(user: "ci", executor: RecordedBootstrapExecutor.new, host_os: "linux").runner_user == Dev::RunnerUser::DEFAULT_NAME
    Dev::JobIdentity.for_host(user: "ci", executor: RecordedBootstrapExecutor.new, host_os: "darwin").runner_user == Etc.getpwuid(Process.uid).name
  end

  test "for_host refuses a platform with no job identity to converge" do
    When
    Dev::JobIdentity.for_host(user: "ci", host_os: "windows")

    Then
    error = raises(Dev::JobIdentity::UnsupportedPlatformError)
    error.message.include?("windows host")
  end

  test "sudoers content grants the one-way SETENV edge from the enrolling user with the identity's umask defaults — #{platform}" do
    Expect "the grantor is the platform's runner user: the operator on a Mac, `runner` on Linux"
    content.include?("#{grantor} ALL=(ai-agent) NOPASSWD:SETENV: ALL")
    content.include?("Defaults>ai-agent env_reset, umask=0002, umask_override")
    content.lines.size == 2
    content.end_with?("\n")

    Where
    platform | grantor  | content
    "darwin" | "human"  | darwin.sudoers_content
    "linux"  | "runner" | linux.sudoers_content
  end

  # dev#569: the identity writes no prefix, so no host grants it brew —
  # not a Mac whose prefix is the operator's, not the box whose prefix is
  # the runner user's (a docker-group user: brew as them is root). The
  # user is named explicitly because on an agent host the suite itself
  # runs as `ai-agent`.
  test "sudoers content grants the identity no brew edge on a prefix another user owns — #{platform}" do
    Given "a host with brew at a prefix owned by #{owner}"
    bootstrap = builder.call

    Expect "only the spawn edge and the umask defaults; the edge's absence is a fact with the one reason"
    bootstrap.sudoers_content.lines.size == 2
    !bootstrap.sudoers_content.include?("brew")
    !bootstrap.sudoers_content.include?("ci ALL=")
    bootstrap.brew_edge.is_a?(Dev::JobIdentity::NoBrewEdge)
    bootstrap.brew_edge.reason == "the agent writes no prefix: pins are the dispatcher's, gems are the agent's own home — plans#26 G"

    Where
    platform | owner    | builder
    "darwin" | "human"  | -> { Dev::JobIdentityTest.darwin(user: "ci", brew_executable: "/opt/homebrew/bin/brew", owner_of: ->(_path) { "human" }) }
    "linux"  | "runner" | -> { Dev::JobIdentityTest.linux(user: "ci", brew_executable: "/home/linuxbrew/.linuxbrew/bin/brew", owner_of: RUNNER_OWNS_LINUXBREW) }
  end

  test "the no-brew-edge fact is the same whether the host has brew or not — #{what}" do
    Expect "one reason, independent of the prefix: the posture, not a waiver"
    bootstrap.brew_edge.equal?(Dev::JobIdentity::NO_BREW_EDGE)
    bootstrap.sudoers_content.lines.size == 2

    Where
    what                        | bootstrap
    "no brew discovered"        | darwin(brew_executable: nil)
    "a prefix no longer there"  | darwin(brew_executable: "/dev-test-gone-#{Process.pid}/bin/brew")
    "the identity owns the prefix" | darwin(user: "human", brew_executable: "/opt/homebrew/bin/brew", owner_of: ->(_path) { "human" })
  end

  # dev#558: the lock-dir grant was keyed on the brew edge; with the edge
  # retired it is keyed on what it was always about — a prefix the
  # identity reads but does not own.
  test "the shared brew prefix is the one another user owns — #{what}" do
    Expect "the prefix and its lock dir, or neither"
    [bootstrap.shared_brew_prefix, bootstrap.brew_locks_dir] == [prefix, prefix && File.join(prefix, "var", "homebrew", "locks")]

    Where
    what                             | bootstrap                                                                                               | prefix
    "the runner user's Linuxbrew"    | linux(brew_executable: "/home/linuxbrew/.linuxbrew/bin/brew", owner_of: RUNNER_OWNS_LINUXBREW)          | "/home/linuxbrew/.linuxbrew"
    "the operator's Mac prefix"      | darwin(brew_executable: "/opt/homebrew/bin/brew", owner_of: ->(_path) { "human" })                      | "/opt/homebrew"
    "a prefix the identity owns itself" | darwin(user: "human", brew_executable: "/opt/homebrew/bin/brew", owner_of: ->(_path) { "human" }) | nil
    "a prefix no longer there"       | linux(brew_executable: "/dev-test-gone-#{Process.pid}/bin/brew", owner_of: RUNNER_OWNS_LINUXBREW)       | nil
    "no brew"                        | linux(brew_executable: nil)                                                                             | nil
  end

  # plans#59: one record of the env both services carry — the user, the
  # group the dispatcher shares fresh workspaces with (read from here
  # rather than defaulted), and the slot (dev#485). The keys keep their
  # AI_FLOW_ spelling: they are the contract with ai-flow's dispatcher.
  test "the service env names the user, the data root's group and the slot — #{platform}" do
    Expect
    bootstrap.service_env(3) == {
      "AI_FLOW_AGENT_USER" => "ci",
      "AI_FLOW_AGENT_GROUP" => Dev::DataRoot::GROUP,
      "AI_FLOW_RUNNER_SLOT" => "3",
    }
    Dev::DataRoot::GROUP == "dev"

    Where
    platform | bootstrap
    "darwin" | darwin(user: "ci")
    "linux"  | linux(user: "ci")
  end

  test "a cooperative dir is in the data root's group and setgid, read with the platform's stat — #{platform}" do
    Given "a real directory whose stat the executor answers as #{answer.inspect}"
    dir = Dir.mktmpdir
    executor = RecordedBootstrapExecutor.new(capture_results: { stat_argv.call(dir) => answer })
    bootstrap = builder.call(executor)

    Expect
    bootstrap.cooperative_dir?(dir) == cooperative
    !bootstrap.cooperative_dir?(File.join(dir, "absent"))

    Where
    platform | builder                                                        | stat_argv                                | answer              | cooperative
    "darwin" | ->(ex) { Dev::JobIdentityTest.darwin(executor: ex) }           | ->(p) { ["stat", "-f", "%Sg %Sp", p] }   | "dev drwxrwsr-x\n"  | true
    "darwin" | ->(ex) { Dev::JobIdentityTest.darwin(executor: ex) }           | ->(p) { ["stat", "-f", "%Sg %Sp", p] }   | "ai drwxrwsr-x\n"   | false
    "darwin" | ->(ex) { Dev::JobIdentityTest.darwin(executor: ex) }           | ->(p) { ["stat", "-f", "%Sg %Sp", p] }   | "dev drwxrwxr-x\n"  | false
    "linux"  | ->(ex) { Dev::JobIdentityTest.linux(executor: ex) }            | ->(p) { ["stat", "-c", "%G %A", p] }     | "dev drwxrwsr-x\n"  | true
    "linux"  | ->(ex) { Dev::JobIdentityTest.linux(executor: ex) }            | ->(p) { ["stat", "-c", "%G %A", p] }     | "dev drwxr-xr-x\n"  | false
  end

  test "SudoUserExecutor crosses to the user, with the adapter's prelude between sudo and the command" do
    Given "a recorded executor behind the user seam, with Linux's prelude"
    executor = RecordedBootstrapExecutor.new(capture_results: { ["sudo", "-n", "-H", "-u", "ci", "--", "env", "-C", "/", "id"] => "ci\n" })
    as_agent = Dev::JobIdentity::SudoUserExecutor.new(executor: executor, user: "ci", prelude: %w[env -C /])

    When "running, probing and capturing"
    as_agent.run("true")
    probed = as_agent.quiet?("true")
    captured = as_agent.capture("id")

    Then "run streams without -n; probes and captures never prompt"
    executor.runs == [["sudo", "-H", "-u", "ci", "--", "env", "-C", "/", "true"]]
    executor.probes == [["sudo", "-n", "-H", "-u", "ci", "--", "env", "-C", "/", "true"]]
    !probed
    captured == "ci\n"
  end

  # The real executor is the true admin-CLI boundary; prove the thin wrapper
  # with cheap real processes instead of mocking Kernel/Open3.
  test "Executor#run reports the child's success, honoring chdir" do
    Given "the real executor"
    executor = Dev::JobIdentity::Executor.new

    Expect "success and failure map to true/false, in and out of a chdir"
    executor.run("true")
    !executor.run("false")
    executor.run("true", chdir: Dir.mktmpdir)
  end

  test "Executor#quiet? probes silently and survives a missing binary" do
    Given "the real executor"
    executor = Dev::JobIdentity::Executor.new

    Expect
    executor.quiet?("true")
    !executor.quiet?("false")
    !executor.quiet?("dev-test-no-such-binary-#{Process.pid}")
  end

  test "Executor#capture returns stdout on success and empty otherwise" do
    Given "the real executor"
    executor = Dev::JobIdentity::Executor.new

    Expect
    executor.capture("echo", "hello") == "hello\n"
    executor.capture("false") == ""
    executor.capture("dev-test-no-such-binary-#{Process.pid}") == ""
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/agent_bootstrap"
require "dev/agent_bootstrap/darwin"
require "dev/agent_bootstrap/linux"
require "support/recorded_bootstrap_executor"
require "etc"
require "stringio"
require "tmpdir"

# The contract's own facts — what both adapters share: the sudoers
# drop-in, the brew edge, the service env, the executor boundary. The
# platform steps are each adapter's test (agent_bootstrap/*_test.rb).
transform!(RSpock::AST::Transformation)
class Dev::AgentBootstrapTest < Minitest::Test
  # The owner lookup the box answers: the Linuxbrew prefix is the runner
  # user's (dev#337), nothing else is anyone's.
  RUNNER_OWNS_LINUXBREW = ->(path) { path == "/home/linuxbrew/.linuxbrew" ? "runner" : nil }

  # The adapters over a recorded executor, with no tap and tmp paths —
  # class methods so Where tables (evaluated in class scope) can build them.
  class << self
    def darwin(**kwargs)
      Dev::AgentBootstrap::Darwin.new(
        runner_user: "human", executor: RecordedBootstrapExecutor.new, tap: nil,
        data_root: Dir.mktmpdir, home_dev: File.join(Dir.mktmpdir, "absent"), brew_executable: nil, **kwargs
      )
    end

    def linux(**kwargs)
      Dev::AgentBootstrap::Linux.new(
        executor: RecordedBootstrapExecutor.new, tap: nil,
        data_root: Dir.mktmpdir, systemd_dir: Dir.mktmpdir, brew_executable: nil, **kwargs
      )
    end
  end

  test "sudoers content grants the one-way SETENV edge from the enrolling user with the agent umask defaults — #{platform}" do
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

  # The prefix owner is whoever runs the suite, so the agent is named
  # explicitly: on an agent host the suite itself runs as `ai-agent`, and the
  # default would make the owner the agent — a waived edge, not a granted one.
  test "sudoers content grants the agent a brew edge to the stat'd prefix owner" do
    Given "a host with brew at a known prefix owned by the human"
    dir = Dir.mktmpdir
    brew = File.join(dir, "bin", "brew")
    FileUtils.mkdir_p(File.dirname(brew))
    File.write(brew, "")
    owner = Etc.getpwuid(File.stat(dir).uid).name
    content = self.class.darwin(agent_user: "ci", brew_executable: brew).sudoers_content

    Expect "the agent may run exactly brew as the prefix owner, NOPASSWD, with the assignments dev's escalation hands sudo (SETENV)"
    content.include?("ci ALL=(#{owner}) NOPASSWD:SETENV: #{brew}")
    !content.include?("NOPASSWD: #{brew}")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  # dev#568: the brew the edge grants is the one under the prefix dev
  # resolves (Settings.brew_prefix) — one resolution, not a second list of
  # standard locations beside it. The prefix's own `bin/brew`, never its
  # realpath: Linuxbrew's is a link into `<prefix>/Homebrew/bin`, and brew
  # takes its prefix from the path it is invoked by.
  test "the host's brew is <prefix>/bin/brew under the resolved prefix — #{what}" do
    Given "a prefix #{what}"
    dir = Dir.mktmpdir
    prefix = File.join(dir, "prefix")
    send(layout, prefix)

    Expect
    Dev::AgentBootstrap.host_brew(prefix: resolved ? prefix : nil) == (found ? File.join(prefix, "bin", "brew") : nil)

    Cleanup
    FileUtils.rm_rf(dir)

    Where
    what                                  | resolved | layout                 | found
    "with brew at bin/brew"               | true     | :brew_at               | true
    "linking bin/brew into Homebrew/bin"  | true     | :linuxbrew_at          | true
    "without a bin/brew"                  | true     | :empty_bin_at          | false
    "unresolved (a machine without brew)" | false    | :empty_bin_at          | false
  end

  # macOS's layout: brew itself at <prefix>/bin/brew.
  def brew_at(prefix)
    executable(File.join(prefix, "bin", "brew"))
  end

  # Linuxbrew's layout: <prefix>/bin/brew a link into <prefix>/Homebrew/bin.
  def linuxbrew_at(prefix)
    executable(File.join(prefix, "Homebrew", "bin", "brew"))
    FileUtils.mkdir_p(File.join(prefix, "bin"))
    File.symlink(File.join("..", "Homebrew", "bin", "brew"), File.join(prefix, "bin", "brew"))
  end

  def empty_bin_at(prefix)
    FileUtils.mkdir_p(File.join(prefix, "bin"))
  end

  def executable(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "")
    FileUtils.chmod(0o755, path)
  end

  # plans#59: on the box the prefix is the runner user's (dev#337), so the
  # brew edge is agent → runner, onto the Linuxbrew path by its realpath.
  test "on Linux the brew edge targets the runner user's Linuxbrew prefix" do
    Given "a Linux host whose Linuxbrew prefix stats as runner's"
    bootstrap = self.class.linux(brew_executable: "/home/linuxbrew/.linuxbrew/bin/brew", owner_of: RUNNER_OWNS_LINUXBREW)

    When "reading the edge"
    edge = bootstrap.brew_edge

    Then
    edge.is_a?(Dev::AgentBootstrap::BrewEdge)
    edge.owner == "runner"
    edge.path == "/home/linuxbrew/.linuxbrew/bin/brew"
    bootstrap.sudoers_content.lines.last == "ai-agent ALL=(runner) NOPASSWD:SETENV: /home/linuxbrew/.linuxbrew/bin/brew\n"
  end

  # dev#365: status inspects the host against the same facts the drop-in
  # is written from, so they are exposed once and the rule rendered from them.
  test "the brew edge is exposed as facts — agent, stat'd owner, brew path — and the drop-in carries exactly their rule" do
    Given "a host with brew at a known prefix owned by the human"
    dir = Dir.mktmpdir
    brew = File.join(dir, "bin", "brew")
    FileUtils.mkdir_p(File.dirname(brew))
    File.write(brew, "")
    owner = Etc.getpwuid(File.stat(dir).uid).name
    bootstrap = self.class.darwin(agent_user: "ci", brew_executable: brew)

    When "reading the edge"
    edge = bootstrap.brew_edge

    Then "the facts are the three the rule names, every tag on it, and the content is built from them"
    edge.is_a?(Dev::AgentBootstrap::BrewEdge)
    edge.agent == "ci"
    edge.owner == owner
    edge.path == brew
    Dev::AgentBootstrap::EDGE_TAGS.all? { |tag| edge.sudoers_rule.include?(tag) }
    bootstrap.sudoers_content.lines.last == "#{edge.sudoers_rule}\n"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "sudoers content omits the brew edge when brew is absent (#{what}), and says why" do
    Expect "only the spawn edge and the umask defaults remain; the waiver names the missing brew"
    bootstrap.sudoers_content.lines.size == 2
    bootstrap.brew_edge.is_a?(Dev::AgentBootstrap::NoBrewEdge)
    bootstrap.brew_edge.reason == "no brew on this host"

    Where
    what                        | bootstrap
    "no brew discovered"        | darwin(brew_executable: nil)
    "a prefix no longer there"  | darwin(brew_executable: "/dev-test-gone-#{Process.pid}/bin/brew")
  end

  test "sudoers content omits the brew edge when the agent already owns the prefix, and says why" do
    Given "a brew prefix owned by the agent user itself"
    dir = Dir.mktmpdir
    brew = File.join(dir, "bin", "brew")
    FileUtils.mkdir_p(File.dirname(brew))
    File.write(brew, "")
    owner = Etc.getpwuid(File.stat(dir).uid).name
    bootstrap = self.class.darwin(agent_user: owner, brew_executable: brew)

    Expect "no self-edge is emitted; the waiver names the owner"
    !bootstrap.sudoers_content.include?(brew)
    bootstrap.brew_edge.is_a?(Dev::AgentBootstrap::NoBrewEdge)
    bootstrap.brew_edge.reason == "#{owner} owns the brew prefix #{dir}"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  # plans#59: one record of the env both services carry — the agent user,
  # the group ai-flow shares fresh workspaces with (read from here rather
  # than defaulted), and the slot (dev#485).
  test "the service env names the agent user, the data root's group and the slot — #{platform}" do
    Expect
    bootstrap.service_env(3) == {
      "AI_FLOW_AGENT_USER" => "ci",
      "AI_FLOW_AGENT_GROUP" => Dev::DataRoot::GROUP,
      "AI_FLOW_RUNNER_SLOT" => "3",
    }
    Dev::DataRoot::GROUP == "dev"

    Where
    platform | bootstrap
    "darwin" | darwin(agent_user: "ci")
    "linux"  | linux(agent_user: "ci")
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
    "darwin" | ->(ex) { Dev::AgentBootstrapTest.darwin(executor: ex) }        | ->(p) { ["stat", "-f", "%Sg %Sp", p] }   | "dev drwxrwsr-x\n"  | true
    "darwin" | ->(ex) { Dev::AgentBootstrapTest.darwin(executor: ex) }        | ->(p) { ["stat", "-f", "%Sg %Sp", p] }   | "ai drwxrwsr-x\n"   | false
    "darwin" | ->(ex) { Dev::AgentBootstrapTest.darwin(executor: ex) }        | ->(p) { ["stat", "-f", "%Sg %Sp", p] }   | "dev drwxrwxr-x\n"  | false
    "linux"  | ->(ex) { Dev::AgentBootstrapTest.linux(executor: ex) }         | ->(p) { ["stat", "-c", "%G %A", p] }     | "dev drwxrwsr-x\n"  | true
    "linux"  | ->(ex) { Dev::AgentBootstrapTest.linux(executor: ex) }         | ->(p) { ["stat", "-c", "%G %A", p] }     | "dev drwxr-xr-x\n"  | false
  end

  test "SudoAgentExecutor crosses to the agent, with the adapter's prelude between sudo and the command" do
    Given "a recorded executor behind the agent seam, with Linux's prelude"
    executor = RecordedBootstrapExecutor.new(capture_results: { ["sudo", "-n", "-H", "-u", "ci", "--", "env", "-C", "/", "id"] => "ci\n" })
    as_agent = Dev::AgentBootstrap::SudoAgentExecutor.new(executor: executor, agent_user: "ci", prelude: %w[env -C /])

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
end

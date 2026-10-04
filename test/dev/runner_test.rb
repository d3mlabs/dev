# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev"
require "dev/runner"
require "fileutils"
require "dev/shadowenv_ruby"
require "stringio"
require "tempfile"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class RunnerTest < Minitest::Test
  extend T::Sig
  include SorbetHelper

  test "run with empty argv prints usage" do
    Given "a Runner with a dev.yml"
    out = StringIO.new
    runner = build_runner(commands: { "up" => { "run" => "./bin/up.rb", "desc" => "Setup" } }, out: out)

    When "we run with empty argv"
    runner.run([])

    Then "the root's usage is printed: the tool's invocation, the project's name, its commands, the help hint"
    out.string.include?("Usage: dev <command> [args...]")
    out.string.include?("Development commands for testproject")
    out.string.include?("up")
    out.string.include?("Setup")
    out.string.lines.last == "Run 'dev help <command>' for a command's usage.\n"
  end

  test "run with --help prints usage" do
    Given "a Runner"
    out = StringIO.new
    runner = build_runner(out: out)

    When "we run with --help"
    runner.run(["--help"])

    Then "usage is printed"
    out.string.include?("Usage: dev <command> [args...]")
  end

  test "run with -h prints usage" do
    Given "a Runner"
    out = StringIO.new
    runner = build_runner(out: out)

    When "we run with -h"
    runner.run(["-h"])

    Then "usage is printed"
    out.string.include?("Usage: dev <command> [args...]")
  end

  test "help is a command: dev help prints usage and lists itself" do
    Given "a Runner"
    out = StringIO.new
    runner = build_runner(out: out)

    When "we run the help command by name"
    runner.run(["help"])

    Then "usage is printed with help in the development flow section"
    out.string.include?("Usage: dev <command> [args...]")
    out.string.include?("help")
    out.string.include?("Show this usage")
  end

  test "usage renders the grouped sections" do
    Given "a Runner with a project command"
    out = StringIO.new
    runner = build_runner(commands: { "test" => { "run" => "rspec", "desc" => "Run tests" } }, out: out)

    When "we print usage"
    runner.run([])

    Then "the three sections render in order"
    lines = out.string.lines.map(&:chomp)
    lines.index("Project commands:") < lines.index("Lifecycle:")
    lines.index("Lifecycle:") < lines.index("Development flow:")
  end

  test "#{argv.inspect} prints the same root usage as bare dev" do
    Given "two Runners over the same dev.yml"
    commands = { "test" => { "run" => "rspec", "desc" => "Run tests" } }
    bare_out = StringIO.new
    out = StringIO.new

    When "running bare and with the spelling"
    build_runner(commands: commands, out: bare_out).run([])
    build_runner(commands: commands, out: out).run(argv)

    Then "one rendering"
    out.string == bare_out.string
    out.string.include?("  test         Run tests")

    Where
    argv
    ["--help"]
    ["-h"]
    ["help"]
  end

  test "run with unknown command prints error to stderr and exits 1" do
    Given "a Runner"
    runner = build_runner
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).once

    When "we run an unknown command"
    runner.run(["nonexistent"])

    Then "error mentions the command name"
    $stderr.string.include?("nonexistent")
    $stderr.string.include?("dev --help")

    Cleanup
    $stderr = old_stderr
  end

  test "usage lists the deps group in Lifecycle, not the retired flat dependency verbs" do
    Given "a Runner with no project commands"
    out = StringIO.new
    runner = build_runner(commands: {}, out: out)

    When "we print usage"
    runner.run([])

    Then "deps is one row; update-deps / install-deps / check are gone"
    out.string.include?("  deps …       Manage dependencies (update | install | check | path)")
    !out.string.include?("update-deps")
    !out.string.include?("install-deps")
    !out.string.match?(/^  check /)
  end

  test "the retired flat dependency verbs are not found" do
    Given "a Runner"
    runner = build_runner(commands: {})
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).times(3)

    When "running each flat name"
    runner.run(["update-deps"])
    runner.run(["install-deps"])
    runner.run(["check"])

    Then "each falls through to the not-found error"
    $stderr.string.include?("Command 'update-deps' not found")
    $stderr.string.include?("Command 'install-deps' not found")
    $stderr.string.include?("Command 'check' not found")

    Cleanup
    $stderr = old_stderr
  end

  test "usage includes both built-in and project commands" do
    Given "a Runner with project commands"
    out = StringIO.new
    runner = build_runner(commands: {
      "test" => { "run" => "rspec", "desc" => "Run tests" },
      "up" => { "run" => "./bin/up.rb", "desc" => "Setup" },
    }, out: out)

    When "we print usage"
    runner.run([])

    Then "all commands appear"
    out.string.include?("deps …")
    out.string.include?("test")
    out.string.include?("up")
  end

  test "up is a builtin even when the project defines no up command" do
    Given "a Runner with no project commands"
    out = StringIO.new
    runner = build_runner(commands: {}, out: out)

    When "we print usage"
    runner.run([])

    Then "up is listed as the builtin dependency install"
    out.string.include?("up")
    out.string.include?("Install locked deps and bring the build container up")
  end

  test "a project up command keeps the builtin slot's section with its own desc" do
    Given "a Runner whose dev.yml overrides up"
    out = StringIO.new
    runner = build_runner(commands: { "up" => { "run" => "./bin/up.rb", "desc" => "Project setup" } }, out: out)

    When "we print usage"
    runner.run([])

    Then "the override's description wins"
    out.string.include?("Project setup")
    !out.string.include?("Install locked deps and bring the build container up")
  end

  test "usage includes the cd builtin" do
    Given "a Runner with no project commands"
    out = StringIO.new
    runner = build_runner(commands: {}, out: out)

    When "we print usage"
    runner.run([])

    Then "cd is listed"
    out.string.include?("cd")
    out.string.include?("Jump to a checkout")
  end

  test "usage includes the clone builtin" do
    Given "a Runner with no project commands"
    out = StringIO.new
    runner = build_runner(commands: {}, out: out)

    When "we print usage"
    runner.run([])

    Then "clone is listed"
    out.string.include?("clone")
    out.string.include?("Clone a GitHub repo")
  end

  test "the container group is registered with every verb when a build container is configured" do
    Given "a Runner with a build container"
    out = StringIO.new
    runner = build_runner(
      commands: {},
      build: { "container" => { "image" => "myapp-linux", "registry" => "myregistry" } },
      out: out,
    )

    When "we print usage, then the group's usage"
    runner.run([])
    top = out.string.dup
    out.truncate(0)
    out.rewind
    runner.run(["container"])

    Then "the noun is listed at the top and its five verbs inside"
    top.include?("container")
    %w[up down reset tag status].all? { |verb| out.string.lines.any? { |l| l.strip.start_with?(verb) } }
  end

  test "container tag answers through the composition root without touching an engine" do
    Given "a Runner with a build container"
    out = StringIO.new
    runner = build_runner(
      commands: {},
      build: { "container" => { "image" => "myapp-linux", "registry" => "myregistry" } },
      out: out,
    )
    Dev::ContainerEngine.expects(:resolve).never

    When "we ask for the tag"
    runner.run(["container", "tag"])

    Then "the content-addressed tag is the whole output"
    out.string.match?(%r{\Amyregistry/myapp-linux:content-[0-9a-f]{12}\n\z})
  end

  test "#{name} is not registered without a build container" do
    Given "a Runner without a build container"
    runner = build_runner(commands: {})
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).once

    When "we invoke the absent command"
    runner.run(argv)

    Then "it is not found"
    $stderr.string.include?(name)

    Cleanup
    $stderr = old_stderr

    Where
    name        | argv
    "container" | ["container", "status"]
    "down"      | ["down"]
  end

  test "down is registered beside up when a build container is configured" do
    Given "a Runner with a build container"
    out = StringIO.new
    runner = build_runner(
      commands: {},
      build: { "container" => { "image" => "myapp-linux", "registry" => "myregistry" } },
      out: out,
    )

    When "we print usage"
    runner.run([])

    Then "down is listed"
    out.string.lines.any? { |l| l.strip.start_with?("down ") }
  end

  test "runner is ungated: every project catalog lists it" do
    Given "a Runner with a plain dev.yml (no runner block — the key is retired)"
    out = StringIO.new
    runner = build_runner(commands: {}, out: out)

    When "we print usage, then the runner group's usage"
    runner.run([])
    runner.run(["runner"])

    Then "the runner group is listed once (the runner-setup alias is retired, #184), with register and status beneath"
    out.string.include?("  runner …     Enroll or inspect this host as a self-hosted runner")
    !out.string.include?("runner-setup")
    out.string.include?("Usage: dev runner <command> [args...]")
    out.string.include?("  register     Enroll this host")
    out.string.include?("  status       Inspect this host's runner enrollments")
  end

  test "a leftover dev.yml runner block warns and is ignored" do
    Given "a dev.yml still carrying the retired key"
    out = StringIO.new
    old_stderr = $stderr
    $stderr = StringIO.new
    runner = build_runner(commands: {}, runner: { "labels" => "ue-engine" }, out: out)

    When "we print usage"
    runner.run([])

    Then "the run proceeds with a retirement warning"
    $stderr.string.include?("`runner:` is retired")
    out.string.include?("  runner …     Enroll or inspect this host as a self-hosted runner")

    Cleanup
    $stderr = old_stderr
  end

  test "a project group invoked bare prints its usage, and lists as a group in the top-level usage" do
    Given "a dev.yml with a nested test group"
    out = StringIO.new
    runner = build_runner(
      commands: {
        "test" => {
          "desc" => "Test suites",
          "commands" => { "unit" => { "run" => "rspec spec/unit", "desc" => "Unit tests" } },
        },
      },
      out: out,
    )

    When "running the group bare, then the top-level usage"
    runner.run(["test"])
    runner.run([])

    Then "the group's usage renders, and the top-level marks it as a group"
    out.string.include?("Usage: dev test <command> [args...]")
    out.string.include?("  unit         Unit tests")
    out.string.include?("  test …       Test suites")
  end

  test "the deps builtin is a group: bare it prints its usage, listing update, install, check and path" do
    Given "a Runner"
    out = StringIO.new
    runner = build_runner(commands: {}, out: out)

    When "running deps bare"
    runner.run(["deps"])

    Then "the group usage renders the four leaves and nothing else"
    out.string.include?("Usage: dev deps <command> [args...]")
    rows = out.string.lines.map(&:chomp).select { |l| l.start_with?("  ") }
    rows.map { |l| l.split.first } == %w[check install path update]
    out.string.include?("  update       Resolve dependency constraints and write lockfiles")
    out.string.include?("  install      Install locked dependencies on this machine")
    out.string.include?("  check        Check dependency state freshness")
    out.string.include?("  path         Print a locked artifact's path")
  end

  test "dev complete walks the project catalog: top level, then a group's children" do
    Given "a dev.yml with a nested test group"
    out = StringIO.new
    runner = build_runner(
      commands: {
        "test" => {
          "desc" => "Test suites",
          "commands" => { "unit" => { "run" => "rspec spec/unit" }, "e2e" => { "run" => "rspec spec/e2e" } },
        },
      },
      out: out,
    )

    When "completing at the top level, then inside the group"
    runner.run(["complete"])
    top = out.string.lines.map(&:chomp)
    out.truncate(0)
    out.rewind
    runner.run(%w[complete test])
    inside = out.string.lines.map(&:chomp)

    Then "builtins, groups and project commands at the top; the group's children inside; complete itself hidden"
    (%w[help up deps plan test] - top).empty?
    !top.include?("complete")
    inside == %w[e2e unit]
  end

  test "dev complete outside a project offers the projectless catalog, global commands included" do
    Given "a Runner with no dev.yml, over its real service graph"
    out = StringIO.new
    runner = Dev::Runner.new(dev_yaml_path: nil, ui: fake_ui, out: out)

    When "completing at the top level"
    runner.run(["complete"])

    Then "help, up, runner and the global nouns are offered; project-only builtins are not"
    names = out.string.lines.map(&:chomp)
    (%w[help up runner cd clone config cred engine learnings plan] - names).empty?
    !names.include?("deps")
  end

  test "bare dev outside a project prints the projectless root: the global commands and the dev.yml hint" do
    Given "a Runner with no dev.yml, over its real service graph"
    out = StringIO.new
    runner = Dev::Runner.new(dev_yaml_path: nil, ui: fake_ui, out: out)

    When "running bare"
    runner.run([])

    Then "the global commands render with their canonical descriptions, in sections, closing with the hint"
    out.string.include?("Usage: dev <command> [args...]")
    out.string.include?("Commands available outside a project")
    out.string.include?("  cd           #{Dev::Builtins::CdCommand::DESC}")
    out.string.include?("  clone        #{Dev::Builtins::CloneCommand::DESC}")
    out.string.include?("  config …     Manage dev settings")
    out.string.include?("  cred …       Resolve stored credentials")
    out.string.include?("  learnings …  The learnings read path: org knowledge cache, skill links, invariants")
    out.string.include?("  plan …       Sync Cursor plans with GitHub issues")
    out.string.include?("  runner …     Enroll or inspect this host as a self-hosted runner")
    out.string.include?("Lifecycle:")
    out.string.lines.last == "#{Dev::Runner::PROJECTLESS_EPILOGUE}\n"
  end

  test "dev help <path> outside a project renders a global group's usage" do
    Given "a Runner with no dev.yml, over its real service graph"
    out = StringIO.new
    runner = Dev::Runner.new(dev_yaml_path: nil, ui: fake_ui, out: out)

    When "asking for help on plan"
    runner.run(["help", "plan"])

    Then
    out.string.include?("Usage: dev plan <command> [args...]")
    out.string.include?("  pull")
  end

  test "an unknown child of a pure project group is reported with its full path" do
    Given "a dev.yml with a nested test group"
    runner = build_runner(
      commands: { "test" => { "commands" => { "unit" => { "run" => "rspec" } } } },
    )
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).once

    When "running an unknown child"
    runner.run(["test", "bogus"])

    Then "the error names the path as typed"
    $stderr.string.include?("Command 'test bogus' not found")

    Cleanup
    $stderr = old_stderr
  end

  test "run assembles the execution context and hands the command to the service" do
    Given "a Runner over an expecting command service, with a declared toolchain"
    root = Pathname.new(Dir.mktmpdir("runner-context-"))
    File.write(root / "dependencies.rb", <<~RUBY)
      require "dev/deps"
      Dev::Deps.define do
        ruby "9.9.9"
        python "3.12"
      end
    RUBY
    contexts = []
    command_service = typed_mock(Dev::CommandService)
    command_service.stubs(:execute).with { |argv, context:|
      contexts << [argv, context]
      true }
    ui = fake_ui
    runner = build_runner(commands: {}, command_service: command_service, ui: ui, root: root)
    Dev::ShadowenvRuby.stubs(:resolve_ruby_version).with("9.9.9").returns("9.9.9")

    When "we run a command with args"
    runner.run(["test", "--fast"])

    Then "the service got the argv and a fully-assembled context"
    argv, context = contexts.fetch(0)
    argv == ["test", "--fast"]
    context.ui == ui
    context.project!.ruby_version == "9.9.9"
    context.project!.python_version == "3.12"
    context.project!.root == root

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "run without a dev.yml assembles a projectless context" do
    Given "a Runner constructed with no dev.yml anywhere"
    contexts = []
    command_service = typed_mock(Dev::CommandService)
    command_service.stubs(:execute).with { |argv, context:|
      contexts << [argv, context]
      true }
    runner = Dev::Runner.new(dev_yaml_path: nil, ui: fake_ui, command_service: command_service)

    When "running up"
    runner.run(["up"])

    Then "the service got a context with a ui and no project half"
    argv, context = contexts.fetch(0)
    argv == ["up"]
    context.project.nil?
  end

  test "a project command without a dev.yml maps to the no-dev.yml refusal" do
    Given "a Runner with no dev.yml, over its real service graph"
    runner = Dev::Runner.new(dev_yaml_path: nil, ui: fake_ui, out: StringIO.new)
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).once

    When "running a project command"
    runner.run(["test"])

    Then "the refusal names the missing dev.yml"
    $stderr.string.include?("no dev.yml found in this directory or any parent")
    $stderr.string.include?("Run dev from inside a project that defines a dev.yml.")

    Cleanup
    $stderr = old_stderr
  end

  test "project builtins are not registered without a dev.yml" do
    Given "a Runner with no dev.yml, over its real service graph"
    runner = Dev::Runner.new(dev_yaml_path: nil, ui: fake_ui, out: StringIO.new)
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).once

    When "running a project-scoped builtin"
    runner.run(%w[deps install])

    Then "the lookup fails like any other command outside a project"
    $stderr.string.include?("no dev.yml found in this directory or any parent")

    Cleanup
    $stderr = old_stderr
  end

  test "a dev.yml with the removed ruby: key maps to a clean error inside run" do
    Given "a Runner over a dev.yml that still carries ruby:"
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(YAML.dump({ "name" => "testproject", "ruby" => "3.3.0", "commands" => {} }))
    tmp.flush
    runner = Dev::Runner.new(dev_yaml_path: Pathname.new(tmp.path), ui: fake_ui, out: StringIO.new)
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).once

    When "running any command"
    runner.run(["test"])

    Then "the migration message reaches stderr as a dev: error"
    $stderr.string.include?("dev.yml `ruby:` is no longer supported")

    Cleanup
    $stderr = old_stderr
    tmp.close!
  end

  test "a failed waited child exits with the child's status" do
    Given "a Runner whose service raises the child's failure"
    command_service = typed_mock(Dev::CommandService)
    command_service.stubs(:execute).raises(Dev::CommandRunner::CommandFailedError.new(exit_status: 7))
    runner = build_runner(commands: {}, command_service: command_service)
    Kernel.expects(:exit).with(7).once

    When "we run the command"
    runner.run(["up"])

    Then "the expectation on the exit mapping holds"
    true
  end

  test "a signal-killed child exits 128 plus the signal number" do
    Given "a Runner whose service raises the child's signal death"
    command_service = typed_mock(Dev::CommandService)
    command_service.stubs(:execute).raises(Dev::CommandRunner::CommandKilledError.new(signal: 15))
    runner = build_runner(commands: {}, command_service: command_service)
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(143).once

    When "we run the command"
    runner.run(["up"])

    Then "the signal is reported under the dev: prefix"
    $stderr.string.include?("dev: command killed by signal 15")

    Cleanup
    $stderr = old_stderr
  end

  test "a child that never spawned exits 127" do
    Given "a Runner whose service raises the spawn failure"
    command_service = typed_mock(Dev::CommandService)
    command_service.stubs(:execute).raises(Dev::CommandRunner::CommandSpawnError.new)
    runner = build_runner(commands: {}, command_service: command_service)
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(127).once

    When "we run the command"
    runner.run(["up"])

    Then "the spawn failure is reported under the dev: prefix"
    $stderr.string.include?("dev: command could not be spawned")

    Cleanup
    $stderr = old_stderr
  end

  test "an ArgumentError is reported as a clean dev error with exit 1" do
    Given "a Runner whose service raises a usage error"
    command_service = typed_mock(Dev::CommandService)
    command_service.stubs(:execute).raises(ArgumentError.new("usage: dev cache gc [--keep N]"))
    runner = build_runner(commands: {}, command_service: command_service)
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).once

    When "we run the command"
    runner.run(["cache"])

    Then "the message reaches stderr under the dev: prefix"
    $stderr.string.include?("dev: usage: dev cache gc [--keep N]")

    Cleanup
    $stderr = old_stderr
  end

  test "an unmapped error is a dev bug and re-raises with its backtrace" do
    Given "a Runner whose service raises an unmapped error class"
    command_service = typed_mock(Dev::CommandService)
    command_service.stubs(:execute).raises(Dev::Deps::ArtifactStore::PublishOutsideStagingError.new("elsewhere"))
    runner = build_runner(commands: {}, command_service: command_service)

    When "we run the command"
    runner.run(["deps"])

    Then
    raises Dev::Deps::ArtifactStore::PublishOutsideStagingError
  end

  private

  # Every run builds an ExecutionContext (the toolchain pass is eager now),
  # so the helper always pins the project root to a temp dir and stubs the
  # ruby resolution; tests needing specific toolchain behavior re-stub after
  # (mocha matches the latest stub first) or pass their own root.
  def build_runner(name: "testproject", commands: {}, build: nil, runner: nil, command_service: nil,
    ui: fake_ui, out: StringIO.new, root: nil)
    root ||= (@tmp_roots ||= []).push(Pathname.new(Dir.mktmpdir("runner-test-"))).fetch(-1)
    Dev.stubs(:target_project_root).returns(root)
    Dev::ShadowenvRuby.stubs(:resolve_ruby_version).returns("4.0.1")

    yaml = { "name" => name, "commands" => commands }
    yaml["build"] = build if build
    yaml["runner"] = runner if runner
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(YAML.dump(yaml))
    tmp.flush

    Dev::Runner.new(dev_yaml_path: Pathname.new(tmp.path), ui: ui, out: out, command_service: command_service)
  end

  def teardown
    @tmp_roots&.each { |root| FileUtils.rm_rf(root) }
    super
  end

  def fake_ui
    ui = typed_mock(Dev::Cli::Ui)
    ui.stubs(:print_header)
    ui
  end
end

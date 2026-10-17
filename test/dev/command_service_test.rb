# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/command_service"
require "dev/command"
require "pathname"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::CommandServiceTest < Minitest::Test
  include SorbetHelper

  # Builtin fake whose traits drive the service's guard/stamp/admission
  # decisions and whose call records the dispatch.
  class FakeBuiltin < Dev::BuiltinCommand
    attr_reader :calls, :flags

    def initialize(staleness_exempt: false, stamps: false, flags: [], opaque_args: false)
      super()
      @staleness_exempt = staleness_exempt
      @stamps = stamps
      @flags = flags
      @opaque_args = opaque_args
      @calls = []
    end

    def desc = "a builtin"

    def category = Dev::Command::Category::Workflow

    def staleness_exempt? = @staleness_exempt

    def stamps? = @stamps

    def opaque_args? = @opaque_args

    def call(args:, context:)
      @calls << [args, context]
    end
  end

  class << self
    # The parse a builtin receives for those words. A class method: Where
    # cells are evaluated while the class body loads, before any instance.
    #
    # @return [Dev::Cli::ParsedArgs]
    def parsed(words, positionals: [], switches: [], values: {})
      Dev::Cli::ParsedArgs.new(words:, positionals:, switches:, values:)
    end
  end

  def parsed(words, positionals: [], switches: [], values: {})
    self.class.parsed(words, positionals:, switches:, values:)
  end

  def build_service(builtins:, dependency_service:, executor: build_executor)
    Dev::CommandService.new(
      repository: Dev::CommandRepository.new(
        root: Dev::CommandGroup.root(desc: "commands", children: builtins), project_commands: {},
      ),
      executor: executor,
      dependency_service: dependency_service,
    )
  end

  # A real composite (these tests only dispatch builtins, in-process; the
  # project seam's runner is a strict mock that must stay silent).
  def build_executor
    builtin_executor = Dev::BuiltinExecutor.new
    project_executor = Dev::ProjectExecutor.new(command_runner: typed_mock(Dev::CommandRunner))
    Dev::CommandExecutor.new(
      builtin_executor: builtin_executor,
      group_executor: Dev::GroupExecutor.new(usage_printer: Dev::Cli::UsagePrinter.new, out: StringIO.new),
      project_executor: project_executor,
      overridden_executor: Dev::OverriddenExecutor.new(
        builtin_executor: builtin_executor, project_executor: project_executor,
      ),
    )
  end

  def fake_context
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui),
      project: Dev::ProjectContext.new(name: "TestProject", root: Pathname.new("/tmp/service-test"), ruby_version: "4.0.1"),
    )
  end

  def fake_dependency_service
    dependency_service = typed_mock(Dev::DependencyService)
    dependency_service.stubs(:guard!)
    dependency_service.stubs(:lock!)
    dependency_service
  end

  test "execute fetches the command, dispatches it, and passes args and context through" do
    Given "a service over one builtin"
    builtin = FakeBuiltin.new(staleness_exempt: true)
    service = build_service(builtins: { "deps" => builtin }, dependency_service: fake_dependency_service)
    context = fake_context

    When "executing the command"
    service.execute(["deps", "path", "xcode"], context: context)

    Then "the builtin ran once with the args and context"
    builtin.calls == [[parsed(["path", "xcode"], positionals: ["path", "xcode"]), context]]
  end

  test "execute raises CommandNotFoundError (the repository's own) for an unknown name" do
    Given "a service over one builtin"
    service = build_service(builtins: { "deps" => FakeBuiltin.new }, dependency_service: fake_dependency_service)

    When "executing an unknown command"
    service.execute(["nonexistent"], context: fake_context)

    Then "the error bubbles under its native namespace"
    raises Dev::CommandRepository::CommandNotFoundError
  end

  test "execute guards staleness before a non-exempt command" do
    Given "a non-exempt builtin and an expecting dependency service"
    dependency_service = typed_mock(Dev::DependencyService)
    dependency_service.expects(:guard!).once
    service = build_service(
      builtins: { "build" => FakeBuiltin.new(staleness_exempt: false) },
      dependency_service: dependency_service,
    )

    When "executing"
    service.execute(["build"], context: fake_context)

    Then "the expectation on the guard holds"
    true
  end

  test "execute skips the guard for a staleness-exempt command" do
    Given "an exempt builtin (it IS the remediation) and a strict dependency service"
    dependency_service = typed_mock(Dev::DependencyService)
    dependency_service.expects(:guard!).never
    dependency_service.stubs(:lock!)
    service = build_service(
      builtins: { "update-deps" => FakeBuiltin.new(staleness_exempt: true) },
      dependency_service: dependency_service,
    )

    When "executing"
    service.execute(["update-deps"], context: fake_context)

    Then "the guard was never consulted"
    true
  end

  test "execute records the installed stamp after a stamping command succeeds" do
    Given "a stamping builtin and an expecting dependency service"
    dependency_service = typed_mock(Dev::DependencyService)
    dependency_service.stubs(:guard!)
    dependency_service.expects(:lock!).once
    service = build_service(
      builtins: { "install-deps" => FakeBuiltin.new(staleness_exempt: true, stamps: true) },
      dependency_service: dependency_service,
    )

    When "executing"
    service.execute(["install-deps"], context: fake_context)

    Then "the stamp was recorded"
    true
  end

  test "execute never stamps for a non-stamping command" do
    Given "a plain builtin and a strict dependency service"
    dependency_service = typed_mock(Dev::DependencyService)
    dependency_service.stubs(:guard!)
    dependency_service.expects(:lock!).never
    service = build_service(
      builtins: { "deps" => FakeBuiltin.new },
      dependency_service: dependency_service,
    )

    When "executing"
    service.execute(["deps"], context: fake_context)

    Then "no stamp was recorded"
    true
  end

  test "a failed execution skips the stamp" do
    Given "a stamping command whose executor raises the child's failure"
    dependency_service = typed_mock(Dev::DependencyService)
    dependency_service.stubs(:guard!)
    dependency_service.expects(:lock!).never
    executor = typed_mock(Dev::CommandExecutor)
    executor.stubs(:execute).raises(Dev::CommandRunner::CommandFailedError.new(exit_status: 7))
    service = build_service(
      builtins: { "up" => FakeBuiltin.new(staleness_exempt: true, stamps: true) },
      dependency_service: dependency_service,
      executor: executor,
    )

    When "executing"
    service.execute(["up"], context: fake_context)

    Then "the failure bubbled and the stamp was skipped"
    raises Dev::CommandRunner::CommandFailedError
  end

  test "execute descends a group to the child named by argv" do
    Given "a service over a deps group with a path child"
    path = FakeBuiltin.new(staleness_exempt: true)
    group = build_group(children: { "path" => path })
    service = build_service(builtins: { "deps" => group }, dependency_service: fake_dependency_service)
    context = fake_context

    When "executing the full path"
    service.execute(["deps", "path", "xcode"], context: context)

    Then "the child ran with the args after it"
    path.calls == [[parsed(["xcode"], positionals: ["xcode"]), context]]
  end

  test "a command with children invoked bare runs itself, guarding and stamping by its own traits" do
    Given "a guarded, stamping builtin heading a child"
    parent = FakeBuiltin.new(staleness_exempt: false, stamps: true, flags: [Dev::Cli::Flag.new("--fast")])
      .with_children({ "unit" => FakeBuiltin.new })
    dependency_service = typed_mock(Dev::DependencyService)
    dependency_service.expects(:guard!).once
    dependency_service.expects(:lock!).once
    service = build_service(builtins: { "test" => parent }, dependency_service: dependency_service)
    context = fake_context

    When "executing it bare with a flag"
    service.execute(["test", "--fast"], context: context)

    Then "it ran with the flag; the guard and stamp expectations hold"
    parent.calls == [[parsed(["--fast"], switches: ["--fast"]), context]]
  end

  test "a group invoked bare is handed to the executor as itself, unguarded and unstamped" do
    Given "a group and an executor expecting the group node"
    group = build_group(children: { "path" => FakeBuiltin.new })
    dependency_service = typed_mock(Dev::DependencyService)
    dependency_service.expects(:guard!).never
    dependency_service.expects(:lock!).never
    executor = typed_mock(Dev::CommandExecutor)
    context = fake_context
    executor.expects(:execute).with(group, args: no_args, context: context).once
    service = build_service(builtins: { "deps" => group }, dependency_service: dependency_service, executor: executor)

    When "executing the group bare"
    service.execute(["deps"], context: context)

    Then "the expectations hold"
    true
  end

  # --- the flag vocabulary gate (#217) --------------------------------------

  test "#{shape}: #{args.inspect} #{outcome}" do
    Given "a tree with every shape: a group, a builtin with flags, one without, a project command"
    with_flags = FakeBuiltin.new(staleness_exempt: true, flags: [Dev::Cli::Flag.new("--keep", takes_value: true), Dev::Cli::Flag.new("--tool-caches")])
    without_flags = FakeBuiltin.new(staleness_exempt: true)
    project = Dev::ProjectCommand.new(run: "./bin/test.sh")
    project_executor = typed_mock(Dev::ProjectExecutor)
    forwarded = []
    project_executor.stubs(:exec_into).with { |_command, args:|
      forwarded << args
      true }
    executor = Dev::CommandExecutor.new(
      builtin_executor: Dev::BuiltinExecutor.new,
      group_executor: Dev::GroupExecutor.new(usage_printer: Dev::Cli::UsagePrinter.new, out: StringIO.new),
      project_executor: project_executor,
    )
    service = Dev::CommandService.new(
      repository: Dev::CommandRepository.new(
        root: Dev::CommandGroup.root(desc: "commands", children: {
          "cache" => build_group(children: { "gc" => with_flags }),
          "plain" => without_flags,
        }),
        project_commands: { "test" => project },
      ),
      executor: executor,
      dependency_service: fake_dependency_service,
    )
    # The builtin whose calls the row observes; a group and a project
    # command record nothing in-process.
    node = { "flagged builtin" => with_flags, "plain builtin" => without_flags }[shape]

    When "executing the shape with those args"
    error = begin
      service.execute([*path, *args], context: fake_context)
      nil
    rescue Dev::Cli::FlagVocabulary::UsageError => e
      e
    end

    Then "a known flag is parsed and reaches the builtin; an unknown one is refused before anything runs; " \
      "a project command gets its argv verbatim"
    error.nil? == (expected != :unknown_flag)
    node.nil? || node.calls.map(&:first) == (expected == :unknown_flag ? [] : [expected])
    shape != "project command" || forwarded == [expected.words]
    error.nil? || error.path == path

    Where
    shape             | path            | args             | outcome                                   | expected
    "group"           | ["cache"]       | ["--bogus"]      | "is refused: groups declare no flags"     | :unknown_flag
    "flagged builtin" | ["cache", "gc"] | ["--keep", "3"]  | "is parsed: the value is the next word"   | parsed(["--keep", "3"], values: { "--keep" => ["3"] })
    "flagged builtin" | ["cache", "gc"] | ["--keep=3"]     | "is parsed: the value is inline"          | parsed(["--keep=3"], values: { "--keep" => ["3"] })
    "flagged builtin" | ["cache", "gc"] | ["--hlep"]       | "is refused"                              | :unknown_flag
    "flagged builtin" | ["cache", "gc"] | ["--", "--hlep"] | "is positional after the terminator"      | parsed(["--", "--hlep"], positionals: ["--hlep"])
    "plain builtin"   | ["plain"]       | ["positional"]   | "is admitted: words are never flags"      | parsed(["positional"], positionals: ["positional"])
    "plain builtin"   | ["plain"]       | ["--any"]        | "is refused: nothing is declared"         | :unknown_flag
    "project command" | ["test"]        | ["--help"]       | "is forwarded: the script owns its argv"  | parsed(["--help"], positionals: ["--help"])
    "project command" | ["test"]        | ["--", "--x"]    | "is forwarded with the terminator kept"   | parsed(["--", "--x"], positionals: ["--", "--x"])
  end

  test "#{argv.inspect} runs the help node with #{help_path.inspect}: a help flag at #{shape} asks for that node's usage" do
    Given "a tree holding help, a group with a flagged leaf, and a plain leaf"
    help = FakeBuiltin.new(staleness_exempt: true)
    leaf = FakeBuiltin.new(staleness_exempt: true, flags: [Dev::Cli::Flag.new("--keep", takes_value: true)])
    plain = FakeBuiltin.new(staleness_exempt: true)
    service = build_service(
      builtins: { "help" => help, "cache" => build_group(children: { "gc" => leaf }), "plain" => plain },
      dependency_service: fake_dependency_service,
    )

    When "executing with a help flag among the node's args"
    service.execute(argv, context: fake_context)

    Then "help ran once, with the node's path; the node itself never did"
    help.calls.map { |args, _context| args.positionals } == [help_path]
    leaf.calls.empty?
    plain.calls.empty?

    Where
    shape                       | argv                                 | help_path
    "the root"                  | ["--help"]                           | []
    "the root, short"           | ["-h"]                               | []
    "a group"                   | ["cache", "--help"]                  | ["cache"]
    "a leaf"                    | ["plain", "-h"]                      | ["plain"]
    "a leaf, after a word"      | ["plain", "positional", "--help"]    | ["plain"]
    "a flagged leaf, mid-flags" | ["cache", "gc", "--keep", "3", "-h"] | ["cache", "gc"]
    "the help node itself"      | ["help", "--help"]                   | ["help"]
  end

  test "a help flag after the terminator is positional: #{argv.inspect} reaches the node as #{expected.inspect}" do
    Given "a tree holding help and a plain leaf"
    help = FakeBuiltin.new(staleness_exempt: true)
    plain = FakeBuiltin.new(staleness_exempt: true)
    service = build_service(builtins: { "help" => help, "plain" => plain }, dependency_service: fake_dependency_service)

    When "executing with the terminator before the help flag"
    service.execute(argv, context: fake_context)

    Then "the node ran with the flag as data; help never did"
    plain.calls.map { |args, _context| args.positionals } == [expected]
    help.calls.empty?

    Where
    argv                            | expected
    ["plain", "--", "--help"]       | ["--help"]
    ["plain", "x", "--", "-h", "y"] | ["x", "-h", "y"]
  end

  test "an opaque node's help flag is its own: no rewrite, forwarded as typed" do
    Given "a tree holding help and an opaque builtin"
    help = FakeBuiltin.new(staleness_exempt: true)
    opaque = FakeBuiltin.new(staleness_exempt: true, opaque_args: true)
    service = build_service(builtins: { "help" => help, "complete" => opaque }, dependency_service: fake_dependency_service)

    When "executing with a help flag among its words"
    service.execute(["complete", "plan", "--help"], context: fake_context)

    Then
    opaque.calls.map { |args, _context| args.words } == [["plan", "--help"]]
    help.calls.empty?
  end

  test "an opaque builtin's args bypass the gate, terminator included" do
    Given "a builtin whose words are another command's argv (as complete's are)"
    builtin = FakeBuiltin.new(staleness_exempt: true, opaque_args: true)
    service = build_service(builtins: { "complete" => builtin }, dependency_service: fake_dependency_service)

    When "executing with foreign flags and a terminator"
    service.execute(["complete", "plan", "pull", "--merge", "--", "-h"], context: fake_context)

    Then "every word arrived as typed"
    builtin.calls.map { |args, _context| args.words } == [["plan", "pull", "--merge", "--", "-h"]]
  end

  test "an unknown flag is refused before the staleness guard gets to nag" do
    Given "a non-exempt builtin and a strict dependency service"
    dependency_service = typed_mock(Dev::DependencyService)
    dependency_service.expects(:guard!).never
    service = build_service(builtins: { "build" => FakeBuiltin.new }, dependency_service: dependency_service)

    When "executing with a flag it does not declare"
    service.execute(["build", "--bogus"], context: fake_context)

    Then
    raises Dev::Cli::FlagVocabulary::UnknownFlagError
  end

  def build_group(children:)
    Dev::CommandGroup.new(
      path: ["group"], desc: "a group", category: Dev::Command::Category::Workflow, children: children,
    )
  end

  test "root serves the repository's tree" do
    Given "a service over one builtin"
    builtin = FakeBuiltin.new
    service = build_service(builtins: { "deps" => builtin }, dependency_service: fake_dependency_service)

    Expect "the tree flows through the service (the onion rule)"
    service.root.children == { "deps" => builtin }
  end

  test "empty argv resolves to the root, handed to the executor as a group" do
    Given "an executor expecting the root"
    dependency_service = typed_mock(Dev::DependencyService)
    dependency_service.expects(:guard!).never
    executor = typed_mock(Dev::CommandExecutor)
    context = fake_context
    service = build_service(builtins: { "up" => FakeBuiltin.new }, dependency_service: dependency_service, executor: executor)
    executor.expects(:execute).with(service.root, args: no_args, context: context).once

    When "executing bare"
    service.execute([], context: context)

    Then "the expectations hold"
    true
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/command"

# A minimal builtin for exercising the trait defaults, the hierarchy's
# open edge, and the OverriddenCommand composition.
class FakeBuiltin < Dev::BuiltinCommand
  def initialize(desc: "fake builtin", hidden: false, staleness_exempt: false, stamps: false,
    category: Dev::Command::Category::Workflow, &body)
    super()
    @desc = desc
    @hidden = hidden
    @staleness_exempt = staleness_exempt
    @stamps = stamps
    @category = category
    @body = body
  end

  attr_reader :desc, :category

  def hidden? = @hidden

  def staleness_exempt? = @staleness_exempt

  def stamps? = @stamps

  def call(args:, context:)
    @body&.call(args, context)
  end
end unless defined?(FakeBuiltin)

transform!(RSpock::AST::Transformation)
class CommandTest < Minitest::Test
  extend T::Sig
  include SorbetHelper

  test "initialize with only run uses default desc and repl" do
    Given "we build a ProjectCommand with only run"
    cmd = Dev::ProjectCommand.new(run: "./bin/setup.rb")

    Expect "desc and repl have defaults"
    cmd.run == "./bin/setup.rb"
    cmd.desc == "(no description)"
    cmd.repl == false
  end

  test "initialize with all args stores them" do
    Given "we build a ProjectCommand with run, desc, and repl"
    cmd = Dev::ProjectCommand.new(
      run: "./bin/test.rb",
      desc: "Run tests",
      repl: false
    )

    Expect "all attributes match"
    cmd.run == "./bin/test.rb"
    cmd.desc == "Run tests"
    cmd.repl == false
  end

  test "repl can be true explicitly" do
    Given "we build a ProjectCommand with repl: true"
    cmd = Dev::ProjectCommand.new(run: "./bin/foo.rb", repl: true)

    Expect "repl is true"
    cmd.repl == true
  end

  test "container defaults to true" do
    Given "a ProjectCommand without explicit container"
    cmd = Dev::ProjectCommand.new(run: "./bin/build.sh")

    Expect
    cmd.container == true
  end

  test "container can be set to false" do
    Given "a ProjectCommand with container: false"
    cmd = Dev::ProjectCommand.new(run: "./bin/deploy.sh", container: false)

    Expect
    cmd.container == false
  end

  test "a ProjectCommand never guards, stamps, or hides by default" do
    Given "a plain ProjectCommand"
    cmd = Dev::ProjectCommand.new(run: "./bin/test.sh")

    Expect "the Command base defaults hold"
    !cmd.hidden?
    !cmd.staleness_exempt?
    !cmd.stamps?
  end

  test "hidden: true marks a ProjectCommand hidden" do
    Given "a ProjectCommand with hidden: true"
    cmd = Dev::ProjectCommand.new(run: "./bin/plumbing.sh", hidden: true)

    Expect
    cmd.hidden?
  end

  test "a builtin without trait overrides gets the Command defaults" do
    Given "a builtin defining only desc and call"
    builtin = Class.new(Dev::BuiltinCommand) do
      def desc = "minimal"

      def call(args:, context:); end
    end.new

    Expect "the Command trait defaults hold"
    !builtin.hidden?
    !builtin.staleness_exempt?
    !builtin.stamps?
  end

  test "subclassing BuiltinCommand is the hierarchy's declared open edge" do
    Given "a builtin subclass"
    builtin = FakeBuiltin.new(desc: "open edge")

    Expect "it enters the sealed hierarchy through the BuiltinCommand variant"
    builtin.is_a?(Dev::BuiltinCommand)
    builtin.is_a?(Dev::Command)
    builtin.desc == "open edge"
  end

  test "including Command directly raises: the seal admits only its four declared variants" do
    When "including the sealed module outside its declaring file"
    Class.new { include Dev::Command }

    Then "sorbet-runtime rejects the include"
    raises RuntimeError
  end

  test "ProjectCommand is final: subclassing raises, keeping descent closed" do
    When "declaring a subclass of the data leaf"
    Class.new(Dev::ProjectCommand)

    Then "sorbet-runtime rejects the open edge"
    raises RuntimeError
  end

  test "OverriddenCommand is final: subclassing raises, keeping descent closed" do
    When "declaring a subclass of the data leaf"
    Class.new(Dev::OverriddenCommand)

    Then "sorbet-runtime rejects the open edge"
    raises RuntimeError
  end

  test "an OverriddenCommand takes desc and hidden from the project override" do
    Given "a builtin slot overridden by a hidden project command"
    builtin = FakeBuiltin.new(desc: "builtin up")
    project = Dev::ProjectCommand.new(run: "./bin/up.sh", desc: "project up", hidden: true)
    cmd = Dev::OverriddenCommand.new(builtin: builtin, project: project)

    Expect "the override owns the slot, so its desc and visibility win"
    cmd.desc == "project up"
    cmd.hidden?
  end

  test "an OverriddenCommand takes guard and stamp traits from the builtin slot" do
    Given "a stamping, staleness-exempt builtin slot overridden by a project command"
    builtin = FakeBuiltin.new(staleness_exempt: true, stamps: true)
    project = Dev::ProjectCommand.new(run: "./bin/up.sh", desc: "project up")
    cmd = Dev::OverriddenCommand.new(builtin: builtin, project: project)

    Expect "the slot's traits hold: a project up: still is the provisioning command"
    cmd.staleness_exempt?
    cmd.stamps?
  end

  test "a ProjectCommand's category is the project group" do
    Given "a plain ProjectCommand"
    cmd = Dev::ProjectCommand.new(run: "./bin/test.sh")

    Expect "it lists under the project commands section"
    cmd.category == Dev::Command::Category::Project
  end

  test "an OverriddenCommand takes its category from the builtin slot" do
    Given "a lifecycle builtin slot overridden by a project command"
    builtin = FakeBuiltin.new(category: Dev::Command::Category::Lifecycle)
    project = Dev::ProjectCommand.new(run: "./bin/up.sh", desc: "project up")
    cmd = Dev::OverriddenCommand.new(builtin: builtin, project: project)

    Expect "the slot's group holds: an overriding up: still lists under Lifecycle"
    cmd.category == Dev::Command::Category::Lifecycle
  end

  test "an OverriddenCommand exposes its typed halves" do
    Given "an overridden command"
    builtin = FakeBuiltin.new
    project = Dev::ProjectCommand.new(run: "./bin/up.sh")
    cmd = Dev::OverriddenCommand.new(builtin: builtin, project: project)

    Expect "both halves are reachable for the executor's dispatch"
    cmd.builtin == builtin
    cmd.project == project
  end

  test "OverriddenCommands compare by value: same builtin instance, equal project, equal children" do
    Given "one builtin, and overrides built alike and differently"
    builtin = FakeBuiltin.new
    a = Dev::OverriddenCommand.new(builtin: builtin, project: Dev::ProjectCommand.new(run: "x"))
    b = Dev::OverriddenCommand.new(builtin: builtin, project: Dev::ProjectCommand.new(run: "x"))
    other_project = Dev::OverriddenCommand.new(builtin: builtin, project: Dev::ProjectCommand.new(run: "y"))
    other_builtin = Dev::OverriddenCommand.new(builtin: FakeBuiltin.new, project: Dev::ProjectCommand.new(run: "x"))
    other_children = Dev::OverriddenCommand.new(
      builtin: builtin, project: Dev::ProjectCommand.new(run: "x"), children: { "c" => FakeBuiltin.new },
    )

    Expect
    a == b
    a.eql?(b)
    a.hash == b.hash
    a != other_project
    a != other_builtin
    a != other_children
    a != Dev::ProjectCommand.new(run: "x")
  end

  test "every command has children, empty by default" do
    Given "one of each shape built without children"
    builtin = FakeBuiltin.new
    project = Dev::ProjectCommand.new(run: "./bin/up.sh")
    overridden = Dev::OverriddenCommand.new(builtin: builtin, project: project)

    Expect "each is a childless node of the tree"
    builtin.children == {}
    project.children == {}
    overridden.children == {}
  end

  test "a builtin heads a subtree when given children, and #with_children copies it over another" do
    Given "a builtin with one child"
    child = FakeBuiltin.new(desc: "child")
    builtin = FakeBuiltin.new(desc: "parent")
    headed = builtin.with_children({ "child" => child })

    Expect "the copy heads the subtree with the same body; the original is untouched"
    headed.children == { "child" => child }
    headed.desc == "parent"
    headed.is_a?(FakeBuiltin)
    builtin.children == {}
  end

  test "a ProjectCommand carries its nested commands as children and #with_children rebuilds it" do
    Given "a project command with a child"
    child = Dev::ProjectCommand.new(run: "rspec spec/unit")
    cmd = Dev::ProjectCommand.new(run: "./bin/test.sh", desc: "All tests", container: false, hidden: true)
    headed = cmd.with_children({ "unit" => child })

    Expect "children are part of the value; every other attribute carries over"
    cmd.children == {}
    headed.children == { "unit" => child }
    headed == Dev::ProjectCommand.new(
      run: "./bin/test.sh", desc: "All tests", container: false, hidden: true, children: { "unit" => child },
    )
    headed != cmd
  end

  test "an OverriddenCommand's children default to the project's over the builtin's, and can be given" do
    Given "a builtin and a project override, each with a child"
    builtin_child = FakeBuiltin.new(desc: "builtin child")
    project_child = Dev::ProjectCommand.new(run: "b")
    builtin = FakeBuiltin.new.with_children({ "a" => builtin_child, "b" => FakeBuiltin.new })
    project = Dev::ProjectCommand.new(run: "./bin/up.sh", children: { "b" => project_child })

    When "composed with and without explicit children"
    defaulted = Dev::OverriddenCommand.new(builtin: builtin, project: project)
    given = Dev::OverriddenCommand.new(builtin: builtin, project: project, children: { "c" => project_child })

    Then "the default is a plain merge; an explicit subtree replaces it"
    defaulted.children == { "a" => builtin_child, "b" => project_child }
    given.children == { "c" => project_child }
  end

  test "CommandGroup is final: subclassing raises, keeping descent closed" do
    When "declaring a subclass of the composite node"
    Class.new(Dev::CommandGroup)

    Then "sorbet-runtime rejects the open edge"
    raises RuntimeError
  end

  test "a CommandGroup is a Command holding its path, children, and declared listing traits" do
    Given "a group over a builtin"
    path = FakeBuiltin.new(desc: "print a path")
    group = Dev::CommandGroup.new(
      path: ["deps"],
      desc: "Dependency lookups",
      category: Dev::Command::Category::Lifecycle,
      children: { "path" => path },
      hidden: true,
    )

    Expect "it enters the sealed hierarchy as its own variant, traits as declared"
    group.is_a?(Dev::Command)
    group.path == ["deps"]
    group.children == { "path" => path }
    group.desc == "Dependency lookups"
    group.category == Dev::Command::Category::Lifecycle
    group.hidden?
  end

  test "a group is staleness-exempt and never stamps: invoked bare it only prints usage" do
    Given "a group"
    group = build_group(children: { "path" => FakeBuiltin.new })

    Expect "the guard traits are the usage-print traits"
    group.staleness_exempt?
    !group.stamps?
  end

  test "a group with no children is unrepresentable" do
    When "declaring an empty group"
    build_group(children: {})

    Then
    raises Dev::CommandGroup::EmptyGroupError
  end

  test "a group may nest another group as a child" do
    Given "a two-level tree"
    inner = build_group(children: { "unit" => FakeBuiltin.new })
    outer = build_group(children: { "test" => inner })

    Expect "the child is reachable by name"
    outer.children.fetch("test") == inner
  end

  test "groups compare by value" do
    Given "two groups built alike and one that differs in a child"
    child = FakeBuiltin.new
    a = build_group(children: { "x" => child })
    b = build_group(children: { "x" => child })
    c = build_group(children: { "y" => child })

    Expect "equality and hash follow the declared attributes"
    a == b
    a.eql?(b)
    a.hash == b.hash
    a != c
    a != Dev::ProjectCommand.new(run: "x")
  end

  sig { params(children: T::Hash[String, Dev::Command]).returns(Dev::CommandGroup) }
  def build_group(children:)
    Dev::CommandGroup.new(
      path: ["group"],
      desc: "a group",
      category: Dev::Command::Category::Workflow,
      children: children,
    )
  end

  test "#== returns #{expected} for #{cmd1} vs #{cmd2}" do
    Given "we compare the two commands"
    result = (cmd1 == cmd2)

    Expect "the result matches"
    result == expected

    Where
    cmd1 | cmd2 | expected
    Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false) | Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false) | true
    Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false) | Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: true)  | false
    Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false) | Dev::ProjectCommand.new(run: "r1", desc: "d2", repl: false) | false
    Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false) | Dev::ProjectCommand.new(run: "r2", desc: "d1", repl: false) | false
    Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false) | "not a command"                                              | false
    Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false) | nil                                                          | false
  end

  test "#== considers container field" do
    Given "two commands differing only in container"
    a = Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false, container: true)
    b = Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false, container: false)

    Expect
    a != b
  end

  test "#eql? returns #{expected} for #{other}" do
    Given "a reference command"
    cmd = Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false)

    Expect "eql? returns the expected result"
    cmd.eql?(other) == expected

    Where
    other | expected
    Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false) | true
    Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: true)  | false
    Dev::ProjectCommand.new(run: "r1", desc: "d2", repl: false) | false
    Dev::ProjectCommand.new(run: "r2", desc: "d1", repl: false) | false
    "not a command"                                              | false
    nil                                                          | false
  end

  test "#hash equality is #{expected} for #{cmd1} vs #{cmd2}" do
    Given "we compare hashes of the two commands"
    result = (cmd1.hash == cmd2.hash)

    Expect "hash equality matches"
    result == expected

    Where
    cmd1 | cmd2 | expected
    Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false) | Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false) | true
    Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false) | Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: true)  | false
    Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false) | Dev::ProjectCommand.new(run: "r1", desc: "d2", repl: false) | false
    Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false) | Dev::ProjectCommand.new(run: "r2", desc: "d1", repl: false) | false
  end

  test "#hash differs when container differs" do
    Given "two commands differing only in container"
    a = Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false, container: true)
    b = Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false, container: false)

    Expect
    a.hash != b.hash
  end
end

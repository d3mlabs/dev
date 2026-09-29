# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/command_repository"
require "dev/command"

# A named no-op builtin for assembly assertions.
class RepositoryFakeBuiltin < Dev::BuiltinCommand
  def initialize(desc: "a builtin", hidden: false)
    super()
    @desc = desc
    @hidden = hidden
  end

  attr_reader :desc

  def hidden? = @hidden

  def category = Dev::Command::Category::Workflow

  def call(args:, context:); end
end unless defined?(RepositoryFakeBuiltin)

transform!(RSpock::AST::Transformation)
class Dev::CommandRepositoryTest < Minitest::Test
  ROOT_DESC = "Development commands for testproject"

  def build_builtin(desc: "a builtin", hidden: false)
    RepositoryFakeBuiltin.new(desc: desc, hidden: hidden)
  end

  # Look a top-level command up the way the service does: one token from
  # the root.
  def fetch(repository, name)
    repository.resolve([name]).command
  end

  test "root is the declared root over the assembled children, at the empty path" do
    Given "a repository with one builtin and one project command"
    builtin = build_builtin(desc: "resolve deps")
    project = Dev::ProjectCommand.new(run: "./bin/test.sh", desc: "Run tests")
    repository = build_repository(builtins: { "update-deps" => builtin }, project_commands: { "test" => project })

    Expect "the root keeps its desc; its children are the assembled tree"
    repository.root.path == []
    repository.root.desc == ROOT_DESC
    repository.root.children == { "update-deps" => builtin, "test" => project }
  end

  test "a builtin-only command resolves as the builtin" do
    Given "a repository with one builtin and no project commands"
    builtin = build_builtin(desc: "resolve deps")
    repository = build_repository(builtins: { "update-deps" => builtin }, project_commands: {})

    Expect "the builtin occupies its slot"
    fetch(repository, "update-deps") == builtin
  end

  test "a project-only command resolves as the ProjectCommand" do
    Given "a repository with one project command beside an unrelated builtin"
    project = Dev::ProjectCommand.new(run: "./bin/test.sh", desc: "Run tests")
    repository = build_repository(builtins: { "up" => build_builtin }, project_commands: { "test" => project })

    Expect "the project command occupies its slot"
    fetch(repository, "test") == project
  end

  test "a project command on a builtin's name composes into an OverriddenCommand" do
    Given "a repository where a project up: collides with the up builtin"
    builtin = build_builtin(desc: "built-in up")
    project = Dev::ProjectCommand.new(run: "./bin/up.sh", desc: "project up")
    repository = build_repository(
      builtins: { "up" => builtin },
      project_commands: { "up" => project },
    )

    When "looking up the resolved command"
    resolved = fetch(repository, "up")

    Then "it is the OverriddenCommand composition, desc from the override"
    resolved.is_a?(Dev::OverriddenCommand)
    resolved.builtin == builtin
    resolved.project == project
    resolved.desc == "project up"
  end

  test "the root's children list builtins then project commands, overrides in the builtin's position" do
    Given "a repository with a builtin, a project command, and an override"
    builtin = build_builtin(desc: "built-in up")
    repository = build_repository(
      builtins: { "update-deps" => build_builtin(desc: "resolve"), "up" => builtin },
      project_commands: {
        "up" => Dev::ProjectCommand.new(run: "./bin/up.sh", desc: "project up"),
        "test" => Dev::ProjectCommand.new(run: "rspec", desc: "Run tests"),
      },
    )

    When "listing the root's children"
    commands = repository.root.children

    Then "the override kept the builtin's listing position, with its own desc"
    commands.keys == ["update-deps", "up", "test"]
    commands["up"].desc == "project up"
  end

  test "hidden commands stay in the tree and resolve" do
    Given "a repository with a hidden builtin"
    hidden = build_builtin(desc: "plumbing", hidden: true)
    repository = build_repository(
      builtins: { "provide-image" => hidden, "up" => build_builtin },
      project_commands: {},
    )

    Expect "hidden is a listing trait the printers read; resolution ignores it"
    repository.root.children["provide-image"].hidden?
    fetch(repository, "provide-image") == hidden
  end

  # --- the tree: assembly --------------------------------------------------

  test "a project group stands as itself, nested groups included" do
    Given "a project group with a nested group inside"
    fast = Dev::ProjectCommand.new(run: "rspec --tag fast", desc: "fast")
    unit = build_group(["test", "unit"], children: { "fast" => fast }, category: Dev::Command::Category::Project)
    e2e = Dev::ProjectCommand.new(run: "./bin/e2e.sh", hidden: true)
    test_group = build_group(["test"], children: { "unit" => unit, "e2e" => e2e }, category: Dev::Command::Category::Project)
    repository = build_repository(builtins: { "up" => build_builtin }, project_commands: { "test" => test_group })

    Expect "the parsed node is the resolved node"
    fetch(repository, "test") == test_group
  end

  test "a project command with children stands as itself" do
    Given "a runnable project command heading a child"
    cmd = Dev::ProjectCommand.new(run: "./bin/test.sh", children: { "unit" => Dev::ProjectCommand.new(run: "rspec") })
    repository = build_repository(builtins: { "up" => build_builtin }, project_commands: { "test" => cmd })

    Expect
    fetch(repository, "test") == cmd
  end

  test "a builtin group survives assembly untouched when the project declares nothing on its name" do
    Given "a builtin group"
    group = build_group(["deps"], children: { "path" => build_builtin(desc: "print a path") })
    repository = build_repository(builtins: { "deps" => group }, project_commands: {})

    Expect
    fetch(repository, "deps") == group
  end

  test "a project group on a builtin group's name merges child by child" do
    Given "a builtin deps group with a path child, and a project deps group adding audit and overriding path"
    builtin_path = build_builtin(desc: "builtin path")
    project_path = Dev::ProjectCommand.new(run: "./bin/path.sh", desc: "project path")
    audit = Dev::ProjectCommand.new(run: "./bin/audit.sh", desc: "audit")
    repository = build_repository(
      builtins: { "deps" => build_group(["deps"], children: { "path" => builtin_path }) },
      project_commands: {
        "deps" => build_group(
          ["deps"], desc: "project deps", hidden: true, category: Dev::Command::Category::Project,
          children: { "audit" => audit, "path" => project_path },
        ),
      },
    )

    When "fetching the merged group"
    merged = fetch(repository, "deps")

    Then "the slot's category holds; the project's desc and visibility win; children merge builtin-then-project"
    merged.is_a?(Dev::CommandGroup)
    merged.path == ["deps"]
    merged.category == Dev::Command::Category::Workflow
    merged.desc == "project deps"
    merged.hidden?
    merged.children.keys == ["path", "audit"]
    merged.children["path"] == Dev::OverriddenCommand.new(builtin: builtin_path, project: project_path)
    merged.children["audit"] == audit
  end

  test "a project command with children on a builtin's name is an OverriddenCommand heading the merged children" do
    Given "a builtin up with a child, and a project up with a run and another child"
    builtin_child = build_builtin(desc: "builtin child")
    builtin = build_builtin(desc: "builtin up").with_children({ "a" => builtin_child })
    db = Dev::ProjectCommand.new(run: "./bin/db.sh")
    project = Dev::ProjectCommand.new(run: "./bin/up.sh", desc: "project up", children: { "db" => db })
    repository = build_repository(builtins: { "up" => builtin }, project_commands: { "up" => project })

    When "fetching"
    merged = fetch(repository, "up")

    Then "bare `dev up` still runs the builtin first, then the project run; both children descend"
    merged.is_a?(Dev::OverriddenCommand)
    merged.builtin == builtin
    merged.project == project
    merged.children == { "a" => builtin_child, "db" => db }
  end

  test "a project group on a builtin's name keeps the builtin, heading the merged children" do
    Given "a builtin up and a project up group with only children"
    builtin = build_builtin(desc: "builtin up")
    db = Dev::ProjectCommand.new(run: "./bin/db.sh")
    repository = build_repository(
      builtins: { "up" => builtin },
      project_commands: { "up" => build_group(["up"], children: { "db" => db }, category: Dev::Command::Category::Project) },
    )

    When "fetching"
    merged = fetch(repository, "up")

    Then "bare `dev up` is unchanged; the project only added a subcommand"
    merged.is_a?(RepositoryFakeBuiltin)
    merged.desc == "builtin up"
    merged.children == { "db" => db }
    builtin.children == {}
  end

  test "a project command on a builtin group's name heads the merged children itself" do
    Given "a builtin deps group and a project deps command"
    path = build_builtin
    project = Dev::ProjectCommand.new(run: "./bin/deps.sh", desc: "project deps")
    repository = build_repository(
      builtins: { "deps" => build_group(["deps"], children: { "path" => path }) },
      project_commands: { "deps" => project },
    )

    Expect "the children survive; the bare invocation runs the project command (nothing builtin to run first)"
    fetch(repository, "deps") == project.with_children({ "path" => path })
  end

  test "merging recurses: a project child on a builtin child's name composes at any depth" do
    Given "a two-level builtin tree and a project override two levels down"
    builtin_fast = build_builtin(desc: "builtin fast")
    project_fast = Dev::ProjectCommand.new(run: "rspec --tag fast")
    repository = build_repository(
      builtins: {
        "test" => build_group(["test"], children: {
          "unit" => build_group(["test", "unit"], children: { "fast" => builtin_fast }),
        }),
      },
      project_commands: {
        "test" => build_group(["test"], category: Dev::Command::Category::Project, children: {
          "unit" => build_group(["test", "unit"], category: Dev::Command::Category::Project, children: {
            "fast" => project_fast,
          }),
        }),
      },
    )

    Expect
    fetch(repository, "test").children["unit"].children["fast"] ==
      Dev::OverriddenCommand.new(builtin: builtin_fast, project: project_fast)
  end

  test "a project node cannot land on a builtin-side node that is neither a builtin nor a group: a wiring bug" do
    Given "a builtin tree holding (wrongly) an already-overridden command"
    stray = Dev::OverriddenCommand.new(builtin: build_builtin, project: Dev::ProjectCommand.new(run: "s"))

    When "a project command lands on its name"
    build_repository(builtins: { "x" => stray }, project_commands: { "x" => Dev::ProjectCommand.new(run: "y") })

    Then
    raises Dev::CommandRepository::UnoverridableCommandError
  end

  test "a project-side node that is not a parsed project node cannot merge: a wiring bug" do
    Given "a project command whose child is (wrongly) a builtin, colliding with a builtin child"
    project = Dev::ProjectCommand.new(run: "x", children: { "a" => build_builtin })
    builtin = build_builtin.with_children({ "a" => build_builtin })

    When "assembling"
    build_repository(builtins: { "x" => builtin }, project_commands: { "x" => project })

    Then
    raises Dev::CommandRepository::UnoverridableCommandError
  end

  # --- the tree: resolution ------------------------------------------------

  test "resolve descends the tree while argv names children, returning the node, its path, and the rest" do
    Given "a two-level builtin tree"
    fast = build_builtin(desc: "fast")
    repository = build_repository(
      builtins: {
        "test" => build_group(["test"], children: {
          "unit" => build_group(["test", "unit"], children: { "fast" => fast }),
        }),
      },
      project_commands: {},
    )

    When "resolving a full path with trailing args"
    resolution = repository.resolve(["test", "unit", "fast", "--seed", "1"])

    Then "the leaf, its path, and the args after it"
    resolution.command == fast
    resolution.path == ["test", "unit", "fast"]
    resolution.args == ["--seed", "1"]
  end

  test "resolve stops at a childless command: its args are never descended into" do
    Given "a leaf"
    leaf = build_builtin
    repository = build_repository(builtins: { "up" => leaf }, project_commands: {})

    When "resolving with args that happen to look like names"
    resolution = repository.resolve(["up", "deps"])

    Then
    resolution.command == leaf
    resolution.path == ["up"]
    resolution.args == ["deps"]
  end

  test "resolve descends through a runnable command's children" do
    Given "a builtin with a child"
    child = build_builtin(desc: "child")
    repository = build_repository(
      builtins: { "test" => build_builtin.with_children({ "unit" => child }) }, project_commands: {},
    )

    When "resolving the child"
    resolution = repository.resolve(["test", "unit", "-v"])

    Then
    resolution.command == child
    resolution.path == ["test", "unit"]
    resolution.args == ["-v"]
  end

  test "resolve stops at a runnable command with children when the next token is not a child, forwarding it" do
    Given "a runnable command with children"
    cmd = build_builtin.with_children({ "unit" => build_builtin })
    repository = build_repository(builtins: { "test" => cmd }, project_commands: {})

    When "resolving with a flag after the name"
    resolution = repository.resolve(["test", "--fast"])

    Then "the command is the node; the flag is its arg"
    resolution.command == cmd
    resolution.args == ["--fast"]
  end

  test "resolve returns a group invoked bare" do
    Given "a group"
    group = build_group(["deps"], children: { "path" => build_builtin })
    repository = build_repository(builtins: { "deps" => group }, project_commands: {})

    When "resolving the bare name"
    resolution = repository.resolve(["deps"])

    Then
    resolution.command == group
    resolution.path == ["deps"]
    resolution.args == []
  end

  test "resolve raises CommandNotFoundError naming the full path for an unknown child of a group" do
    Given "a group"
    repository = build_repository(
      builtins: { "deps" => build_group(["deps"], children: { "path" => build_builtin }) },
      project_commands: {},
    )

    When "resolving an unknown child"
    error = assert_raises(Dev::CommandRepository::CommandNotFoundError) { repository.resolve(["deps", "bogus"]) }

    Then "the message reads as typed"
    error.message.include?("'deps bogus'")
  end

  test "resolve raises CommandNotFoundError naming the token for an unknown top-level name: the root is a group too" do
    Given "a repository with one builtin"
    repository = build_repository(builtins: { "up" => build_builtin }, project_commands: {})

    When "resolving an unknown name"
    error = assert_raises(Dev::CommandRepository::CommandNotFoundError) { repository.resolve(["nope"]) }

    Then
    error.message == "Command 'nope' not found"
  end

  test "resolve returns the root for empty argv: bare `dev` prints the root's usage" do
    Given "a repository"
    repository = build_repository(builtins: { "up" => build_builtin }, project_commands: {})

    When "resolving nothing"
    resolution = repository.resolve([])

    Then
    resolution.command == repository.root
    resolution.path == []
    resolution.args == []
  end

  def build_group(path, children:, desc: "group #{path.join(" ")}", category: Dev::Command::Category::Workflow, hidden: false)
    Dev::CommandGroup.new(path: path, desc: desc, category: category, children: children, hidden: hidden)
  end

  # The repository under test, its builtins as the root's children.
  def build_repository(builtins:, project_commands:)
    Dev::CommandRepository.new(root: Dev::CommandGroup.root(desc: ROOT_DESC, children: builtins), project_commands: project_commands)
  end
end

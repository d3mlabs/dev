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
  def build_builtin(desc: "a builtin", hidden: false)
    RepositoryFakeBuiltin.new(desc: desc, hidden: hidden)
  end

  test "fetch returns a builtin-only command as the builtin" do
    Given "a repository with one builtin and no project commands"
    builtin = build_builtin(desc: "resolve deps")
    repository = Dev::CommandRepository.new(builtins: { "update-deps" => builtin }, project_commands: {})

    Expect "the builtin occupies its slot"
    repository.fetch("update-deps") == builtin
  end

  test "fetch returns a project-only command as the ProjectCommand" do
    Given "a repository with one project command and no builtins"
    project = Dev::ProjectCommand.new(run: "./bin/test.sh", desc: "Run tests")
    repository = Dev::CommandRepository.new(builtins: {}, project_commands: { "test" => project })

    Expect "the project command occupies its slot"
    repository.fetch("test") == project
  end

  test "a project command on a builtin's name composes into an OverriddenCommand" do
    Given "a repository where a project up: collides with the up builtin"
    builtin = build_builtin(desc: "built-in up")
    project = Dev::ProjectCommand.new(run: "./bin/up.sh", desc: "project up")
    repository = Dev::CommandRepository.new(
      builtins: { "up" => builtin },
      project_commands: { "up" => project },
    )

    When "looking up the resolved command"
    resolved = repository.fetch("up")

    Then "it is the OverriddenCommand composition, desc from the override"
    resolved.is_a?(Dev::OverriddenCommand)
    resolved.builtin == builtin
    resolved.project == project
    resolved.desc == "project up"
  end

  test "fetch raises CommandNotFoundError for an unknown name" do
    Given "an empty repository"
    repository = Dev::CommandRepository.new(builtins: {}, project_commands: {})

    When "fetching a nonexistent command"
    repository.fetch("nope")

    Then
    raises Dev::CommandRepository::CommandNotFoundError
  end

  test "visible_commands lists builtins then project commands, overrides in the builtin's position" do
    Given "a repository with a builtin, a project command, and an override"
    builtin = build_builtin(desc: "built-in up")
    repository = Dev::CommandRepository.new(
      builtins: { "update-deps" => build_builtin(desc: "resolve"), "up" => builtin },
      project_commands: {
        "up" => Dev::ProjectCommand.new(run: "./bin/up.sh", desc: "project up"),
        "test" => Dev::ProjectCommand.new(run: "rspec", desc: "Run tests"),
      },
    )

    When "listing the visible commands"
    commands = repository.visible_commands

    Then "the override kept the builtin's listing position, with its own desc"
    commands.keys == ["update-deps", "up", "test"]
    commands["up"].desc == "project up"
  end

  test "visible_commands omits hidden commands but fetch still resolves them" do
    Given "a repository with a hidden builtin"
    hidden = build_builtin(desc: "plumbing", hidden: true)
    repository = Dev::CommandRepository.new(
      builtins: { "provide-image" => hidden, "up" => build_builtin },
      project_commands: {},
    )

    Expect "hidden commands stay callable but unlisted"
    !repository.visible_commands.key?("provide-image")
    repository.fetch("provide-image") == hidden
  end

  # --- the tree: assembly --------------------------------------------------

  test "a project group stands as itself, nested groups included" do
    Given "a project group with a nested group inside"
    fast = Dev::ProjectCommand.new(run: "rspec --tag fast", desc: "fast")
    unit = build_group(["test", "unit"], children: { "fast" => fast }, category: Dev::Command::Category::Project)
    e2e = Dev::ProjectCommand.new(run: "./bin/e2e.sh", hidden: true)
    test_group = build_group(["test"], children: { "unit" => unit, "e2e" => e2e }, category: Dev::Command::Category::Project)
    repository = Dev::CommandRepository.new(builtins: {}, project_commands: { "test" => test_group })

    Expect "the parsed node is the resolved node"
    repository.fetch("test") == test_group
  end

  test "a project command with children stands as itself" do
    Given "a runnable project command heading a child"
    cmd = Dev::ProjectCommand.new(run: "./bin/test.sh", children: { "unit" => Dev::ProjectCommand.new(run: "rspec") })
    repository = Dev::CommandRepository.new(builtins: {}, project_commands: { "test" => cmd })

    Expect
    repository.fetch("test") == cmd
  end

  test "a builtin group survives assembly untouched when the project declares nothing on its name" do
    Given "a builtin group"
    group = build_group(["deps"], children: { "path" => build_builtin(desc: "print a path") })
    repository = Dev::CommandRepository.new(builtins: { "deps" => group }, project_commands: {})

    Expect
    repository.fetch("deps") == group
  end

  test "a project group on a builtin group's name merges child by child" do
    Given "a builtin deps group with a path child, and a project deps group adding audit and overriding path"
    builtin_path = build_builtin(desc: "builtin path")
    project_path = Dev::ProjectCommand.new(run: "./bin/path.sh", desc: "project path")
    audit = Dev::ProjectCommand.new(run: "./bin/audit.sh", desc: "audit")
    repository = Dev::CommandRepository.new(
      builtins: { "deps" => build_group(["deps"], children: { "path" => builtin_path }) },
      project_commands: {
        "deps" => build_group(
          ["deps"], desc: "project deps", hidden: true, category: Dev::Command::Category::Project,
          children: { "audit" => audit, "path" => project_path },
        ),
      },
    )

    When "fetching the merged group"
    merged = repository.fetch("deps")

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
    repository = Dev::CommandRepository.new(builtins: { "up" => builtin }, project_commands: { "up" => project })

    When "fetching"
    merged = repository.fetch("up")

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
    repository = Dev::CommandRepository.new(
      builtins: { "up" => builtin },
      project_commands: { "up" => build_group(["up"], children: { "db" => db }, category: Dev::Command::Category::Project) },
    )

    When "fetching"
    merged = repository.fetch("up")

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
    repository = Dev::CommandRepository.new(
      builtins: { "deps" => build_group(["deps"], children: { "path" => path }) },
      project_commands: { "deps" => project },
    )

    Expect "the children survive; the bare invocation runs the project command (nothing builtin to run first)"
    repository.fetch("deps") == project.with_children({ "path" => path })
  end

  test "merging recurses: a project child on a builtin child's name composes at any depth" do
    Given "a two-level builtin tree and a project override two levels down"
    builtin_fast = build_builtin(desc: "builtin fast")
    project_fast = Dev::ProjectCommand.new(run: "rspec --tag fast")
    repository = Dev::CommandRepository.new(
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
    repository.fetch("test").children["unit"].children["fast"] ==
      Dev::OverriddenCommand.new(builtin: builtin_fast, project: project_fast)
  end

  test "a project node cannot land on a builtin-side node that is neither a builtin nor a group: a wiring bug" do
    Given "a builtin tree holding (wrongly) an already-overridden command"
    stray = Dev::OverriddenCommand.new(builtin: build_builtin, project: Dev::ProjectCommand.new(run: "s"))

    When "a project command lands on its name"
    Dev::CommandRepository.new(builtins: { "x" => stray }, project_commands: { "x" => Dev::ProjectCommand.new(run: "y") })

    Then
    raises Dev::CommandRepository::UnoverridableCommandError
  end

  test "a project-side node that is not a parsed project node cannot merge: a wiring bug" do
    Given "a project command whose child is (wrongly) a builtin, colliding with a builtin child"
    project = Dev::ProjectCommand.new(run: "x", children: { "a" => build_builtin })
    builtin = build_builtin.with_children({ "a" => build_builtin })

    When "assembling"
    Dev::CommandRepository.new(builtins: { "x" => builtin }, project_commands: { "x" => project })

    Then
    raises Dev::CommandRepository::UnoverridableCommandError
  end

  # --- the tree: resolution ------------------------------------------------

  test "resolve descends the tree while argv names children, returning the node, its path, and the rest" do
    Given "a two-level builtin tree"
    fast = build_builtin(desc: "fast")
    repository = Dev::CommandRepository.new(
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
    repository = Dev::CommandRepository.new(builtins: { "up" => leaf }, project_commands: {})

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
    repository = Dev::CommandRepository.new(
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
    repository = Dev::CommandRepository.new(builtins: { "test" => cmd }, project_commands: {})

    When "resolving with a flag after the name"
    resolution = repository.resolve(["test", "--fast"])

    Then "the command is the node; the flag is its arg"
    resolution.command == cmd
    resolution.args == ["--fast"]
  end

  test "resolve returns a group invoked bare" do
    Given "a group"
    group = build_group(["deps"], children: { "path" => build_builtin })
    repository = Dev::CommandRepository.new(builtins: { "deps" => group }, project_commands: {})

    When "resolving the bare name"
    resolution = repository.resolve(["deps"])

    Then
    resolution.command == group
    resolution.path == ["deps"]
    resolution.args == []
  end

  test "resolve raises CommandNotFoundError naming the full path for an unknown child of a group" do
    Given "a group"
    repository = Dev::CommandRepository.new(
      builtins: { "deps" => build_group(["deps"], children: { "path" => build_builtin }) },
      project_commands: {},
    )

    When "resolving an unknown child"
    error = assert_raises(Dev::CommandRepository::CommandNotFoundError) { repository.resolve(["deps", "bogus"]) }

    Then "the message reads as typed"
    error.message.include?("'deps bogus'")
  end

  test "resolve raises CommandNotFoundError for #{label}" do
    Given "an empty repository"
    repository = Dev::CommandRepository.new(builtins: {}, project_commands: {})

    When "resolving"
    repository.resolve(argv)

    Then
    raises Dev::CommandRepository::CommandNotFoundError

    Where
    label | argv
    "an unknown top-level name" | ["nope"]
    "empty argv" | []
  end

  def build_group(path, children:, desc: "group #{path.join(" ")}", category: Dev::Command::Category::Workflow, hidden: false)
    Dev::CommandGroup.new(path: path, desc: desc, category: category, children: children, hidden: hidden)
  end
end

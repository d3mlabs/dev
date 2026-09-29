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

  test "a project group assembles into a CommandGroup with its path, project category, and parsed children" do
    Given "a pure project group with a nested group inside"
    fast = Dev::ProjectCommand.new(run: "rspec --tag fast", desc: "fast")
    project_commands = {
      "test" => Dev::ProjectCommandGroup.new(
        desc: "Test suites",
        children: {
          "unit" => Dev::ProjectCommandGroup.new(children: { "fast" => fast }),
          "e2e" => Dev::ProjectCommand.new(run: "./bin/e2e.sh", hidden: true),
        },
      ),
    }
    repository = Dev::CommandRepository.new(builtins: {}, project_commands: project_commands)

    When "fetching the group"
    group = repository.fetch("test")

    Then "it is a CommandGroup mirroring the declaration, paths accumulated"
    group.is_a?(Dev::CommandGroup)
    group.path == ["test"]
    group.desc == "Test suites"
    group.category == Dev::Command::Category::Project
    group.own.nil?
    group.children.keys == ["unit", "e2e"]
    group.children["e2e"].hidden?
    group.children["unit"].path == ["test", "unit"]
    group.children["unit"].children["fast"] == fast
  end

  test "a runnable project group keeps its own leaf" do
    Given "a group with run beside commands"
    own = Dev::ProjectCommand.new(run: "./bin/test.sh", desc: "All tests")
    repository = Dev::CommandRepository.new(
      builtins: {},
      project_commands: {
        "test" => Dev::ProjectCommandGroup.new(
          desc: "All tests", own: own, children: { "unit" => Dev::ProjectCommand.new(run: "rspec") },
        ),
      },
    )

    Expect "the bare invocation's leaf is the project run"
    repository.fetch("test").own == own
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
        "deps" => Dev::ProjectCommandGroup.new(
          desc: "project deps", children: { "audit" => audit, "path" => project_path },
        ),
      },
    )

    When "fetching the merged group"
    merged = repository.fetch("deps")

    Then "the slot's category holds, the override's desc wins, children merge in builtin-then-project order"
    merged.is_a?(Dev::CommandGroup)
    merged.path == ["deps"]
    merged.category == Dev::Command::Category::Workflow
    merged.desc == "project deps"
    merged.children.keys == ["path", "audit"]
    merged.children["path"].is_a?(Dev::OverriddenCommand)
    merged.children["path"].builtin == builtin_path
    merged.children["path"].project == project_path
    merged.children["audit"] == audit
  end

  test "own leaves merge like slots: builtin own + project own compose into an OverriddenCommand" do
    Given "a runnable builtin group and a runnable project group of the same name"
    builtin_own = build_builtin(desc: "builtin own")
    project_own = Dev::ProjectCommand.new(run: "./bin/own.sh", desc: "project own")
    repository = Dev::CommandRepository.new(
      builtins: { "x" => build_group(["x"], children: { "a" => build_builtin }, own: builtin_own) },
      project_commands: {
        "x" => Dev::ProjectCommandGroup.new(own: project_own, children: { "b" => Dev::ProjectCommand.new(run: "b") }),
      },
    )

    When "fetching the merged group"
    merged = repository.fetch("x")

    Then "the own slot is the composition; either side alone would have won it outright"
    merged.own.is_a?(Dev::OverriddenCommand)
    merged.own.builtin == builtin_own
    merged.own.project == project_own
    merged.children.keys == ["a", "b"]
  end

  test "a project group on a builtin group keeps the builtin's own leaf when it declares none" do
    Given "a runnable builtin group and a pure project group"
    builtin_own = build_builtin(desc: "builtin own")
    repository = Dev::CommandRepository.new(
      builtins: { "x" => build_group(["x"], children: { "a" => build_builtin }, own: builtin_own) },
      project_commands: {
        "x" => Dev::ProjectCommandGroup.new(children: { "b" => Dev::ProjectCommand.new(run: "b") }),
      },
    )

    Expect
    repository.fetch("x").own == builtin_own
  end

  test "a project group on a builtin leaf's name makes a group whose own leaf is the overridden builtin" do
    Given "a builtin up leaf and a project up group with its own run"
    builtin = build_builtin(desc: "builtin up")
    project_own = Dev::ProjectCommand.new(run: "./bin/up.sh", desc: "project up")
    db = Dev::ProjectCommand.new(run: "./bin/db.sh")
    repository = Dev::CommandRepository.new(
      builtins: { "up" => builtin },
      project_commands: {
        "up" => Dev::ProjectCommandGroup.new(desc: "project up", own: project_own, children: { "db" => db }),
      },
    )

    When "fetching"
    group = repository.fetch("up")

    Then "bare `dev up` still runs the builtin first, then the project run; `dev up db` descends"
    group.is_a?(Dev::CommandGroup)
    group.own.is_a?(Dev::OverriddenCommand)
    group.own.builtin == builtin
    group.own.project == project_own
    group.category == Dev::Command::Category::Workflow
    group.children == { "db" => db }
  end

  test "a pure project group on a builtin leaf's name keeps the builtin as the own leaf" do
    Given "a builtin up leaf and a project up group with only children"
    builtin = build_builtin(desc: "builtin up")
    repository = Dev::CommandRepository.new(
      builtins: { "up" => builtin },
      project_commands: {
        "up" => Dev::ProjectCommandGroup.new(children: { "db" => Dev::ProjectCommand.new(run: "./bin/db.sh") }),
      },
    )

    Expect "bare `dev up` is unchanged"
    repository.fetch("up").own == builtin
  end

  test "a project leaf on a builtin group's name becomes the group's own leaf" do
    Given "a builtin deps group and a project deps leaf"
    project = Dev::ProjectCommand.new(run: "./bin/deps.sh", desc: "project deps")
    repository = Dev::CommandRepository.new(
      builtins: { "deps" => build_group(["deps"], children: { "path" => build_builtin }) },
      project_commands: { "deps" => project },
    )

    When "fetching"
    group = repository.fetch("deps")

    Then "the children survive; the bare invocation runs the project leaf"
    group.is_a?(Dev::CommandGroup)
    group.own == project
    group.desc == "project deps"
    group.children.keys == ["path"]
  end

  test "a project leaf on a runnable builtin group's name composes with the builtin's own leaf" do
    Given "a runnable builtin group and a project leaf"
    builtin_own = build_builtin(desc: "builtin own")
    project = Dev::ProjectCommand.new(run: "./bin/x.sh")
    repository = Dev::CommandRepository.new(
      builtins: { "x" => build_group(["x"], children: { "a" => build_builtin }, own: builtin_own) },
      project_commands: { "x" => project },
    )

    Expect
    repository.fetch("x").own.is_a?(Dev::OverriddenCommand)
    repository.fetch("x").own.builtin == builtin_own
  end

  test "a project run cannot override a builtin group's own leaf that is not a builtin: a wiring bug" do
    Given "a builtin group whose own leaf is (wrongly) a project command"
    stray_own = Dev::ProjectCommand.new(run: "./bin/stray.sh")
    group = build_group(["x"], children: { "a" => build_builtin }, own: stray_own)

    When "a project leaf lands on the group's name"
    Dev::CommandRepository.new(builtins: { "x" => group }, project_commands: { "x" => Dev::ProjectCommand.new(run: "y") })

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

  test "resolve stops at a leaf: a leaf's args are never descended into" do
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

  test "resolve stops at a runnable group when the next token is not a child, forwarding it as args" do
    Given "a runnable group"
    group = build_group(["test"], children: { "unit" => build_builtin }, own: build_builtin)
    repository = Dev::CommandRepository.new(builtins: { "test" => group }, project_commands: {})

    When "resolving with a flag after the group name"
    resolution = repository.resolve(["test", "--fast"])

    Then "the group is the node; the flag goes to whatever the bare invocation runs"
    resolution.command == group
    resolution.args == ["--fast"]
  end

  test "resolve returns a pure group invoked bare" do
    Given "a pure group"
    group = build_group(["deps"], children: { "path" => build_builtin })
    repository = Dev::CommandRepository.new(builtins: { "deps" => group }, project_commands: {})

    When "resolving the bare name"
    resolution = repository.resolve(["deps"])

    Then
    resolution.command == group
    resolution.path == ["deps"]
    resolution.args == []
  end

  test "resolve raises CommandNotFoundError naming the full path for an unknown child of a pure group" do
    Given "a pure group"
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

  def build_group(path, children:, own: nil)
    Dev::CommandGroup.new(
      path: path, desc: "group #{path.join(" ")}", category: Dev::Command::Category::Workflow,
      children: children, own: own,
    )
  end
end

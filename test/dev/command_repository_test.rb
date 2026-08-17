# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/command_repository"
require "dev/command"

# The repository is service-private in production (private_constant, onion
# rule); tests alias it through const_get rather than weakening the privacy.
CommandRepositoryUnderTest = Dev.const_get(:CommandRepository) unless defined?(CommandRepositoryUnderTest)
unless defined?(CommandNotFoundErrorUnderTest)
  CommandNotFoundErrorUnderTest = CommandRepositoryUnderTest.const_get(:CommandNotFoundError)
end

# A named no-op builtin for assembly assertions.
class RepositoryFakeBuiltin < Dev::BuiltinCommand
  def initialize(desc: "a builtin", hidden: false)
    @desc = desc
    @hidden = hidden
    super()
  end

  attr_reader :desc

  def hidden? = @hidden

  def call(args:, context:); end
end unless defined?(RepositoryFakeBuiltin)

transform!(RSpock::AST::Transformation)
class Dev::CommandRepositoryTest < Minitest::Test
  test "fetch returns a builtin-only command as the builtin" do
    Given "a repository with one builtin and no project commands"
    builtin = RepositoryFakeBuiltin.new(desc: "resolve deps")
    repository = CommandRepositoryUnderTest.new(builtins: { "update-deps" => builtin }, project_commands: {})

    Expect "the builtin occupies its slot"
    repository.fetch("update-deps") == builtin
  end

  test "fetch returns a project-only command as the ProjectCommand" do
    Given "a repository with one project command and no builtins"
    project = Dev::ProjectCommand.new(run: "./bin/test.sh", desc: "Run tests")
    repository = CommandRepositoryUnderTest.new(builtins: {}, project_commands: { "test" => project })

    Expect "the project command occupies its slot"
    repository.fetch("test") == project
  end

  test "a project command on a builtin's name composes into an OverriddenCommand" do
    Given "a repository where a project up: collides with the up builtin"
    builtin = RepositoryFakeBuiltin.new(desc: "built-in up")
    project = Dev::ProjectCommand.new(run: "./bin/up.sh", desc: "project up")
    repository = CommandRepositoryUnderTest.new(
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
    repository = CommandRepositoryUnderTest.new(builtins: {}, project_commands: {})

    When "fetching a nonexistent command"
    repository.fetch("nope")

    Then
    raises CommandNotFoundErrorUnderTest
  end

  test "visible_commands lists builtins then project commands, overrides in the builtin's position" do
    Given "a repository with a builtin, a project command, and an override"
    builtin = RepositoryFakeBuiltin.new(desc: "built-in up")
    repository = CommandRepositoryUnderTest.new(
      builtins: { "update-deps" => RepositoryFakeBuiltin.new(desc: "resolve"), "up" => builtin },
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
    hidden = RepositoryFakeBuiltin.new(desc: "plumbing", hidden: true)
    repository = CommandRepositoryUnderTest.new(
      builtins: { "provide-image" => hidden, "up" => RepositoryFakeBuiltin.new },
      project_commands: {},
    )

    Expect "hidden commands stay callable but unlisted"
    !repository.visible_commands.key?("provide-image")
    repository.fetch("provide-image") == hidden
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/flag_vocabulary"
require "dev/command"

# A builtin declaring a vocabulary, or opaque, for the gate to read.
class VocabularyFakeBuiltin < Dev::BuiltinCommand
  def initialize(flags: [], opaque_args: false)
    super()
    @flags = flags
    @opaque_args = opaque_args
  end

  attr_reader :flags

  def desc = "a builtin"

  def category = Dev::Command::Category::Workflow

  def opaque_args? = @opaque_args

  def call(args:, context:); end
end unless defined?(VocabularyFakeBuiltin)

transform!(RSpock::AST::Transformation)
class Dev::Cli::FlagVocabularyTest < Minitest::Test
  test "#{token.inspect} #{expected ? "is" : "is not"} flag-shaped" do
    Given "the vocabulary"
    vocabulary = Dev::Cli::FlagVocabulary.new

    Expect
    vocabulary.flag?(token) == expected

    Where
    token      | expected
    "-h"       | true
    "--help"   | true
    "--keep=3" | true
    "---x"     | true
    "-"        | false
    "--"       | false
    "word"     | false
    ""         | false
  end

  test "help_requested? sees a help flag anywhere before the terminator: #{args.inspect} → #{expected}" do
    Given "the vocabulary"
    vocabulary = Dev::Cli::FlagVocabulary.new

    Expect
    vocabulary.help_requested?(args) == expected

    Where
    args                              | expected
    ["--help"]                        | true
    ["-h"]                            | true
    ["Carve system", "--org", "-h"]   | true
    ["--help", "--", "x"]             | true
    []                                | false
    ["help"]                          | false
    ["--org"]                         | false
    ["--", "--help"]                  | false
  end

  test "admit passes a declared flag in either form, and strips the terminator" do
    Given "a builtin declaring --keep and --tool-caches"
    vocabulary = Dev::Cli::FlagVocabulary.new
    command = VocabularyFakeBuiltin.new(flags: [Dev::Cli::Flag.new("--keep", takes_value: true), Dev::Cli::Flag.new("--tool-caches")])

    Expect "the args as given, minus the first terminator"
    vocabulary.admit(command, path: ["cache", "gc"], args: ["--keep", "3", "--tool-caches"]) == ["--keep", "3", "--tool-caches"]
    vocabulary.admit(command, path: ["cache", "gc"], args: ["--keep=3"]) == ["--keep=3"]
    vocabulary.admit(command, path: ["cache", "gc"], args: ["--keep", "3", "--", "--bogus", "--"]) ==
      ["--keep", "3", "--bogus", "--"]
    vocabulary.admit(command, path: ["cache", "gc"], args: []) == []
  end

  test "admit lets the help flags through at every node: they are in every vocabulary" do
    Given "a builtin declaring nothing and a group"
    vocabulary = Dev::Cli::FlagVocabulary.new
    group = Dev::CommandGroup.new(
      path: ["deps"], desc: "deps", category: Dev::Command::Category::Lifecycle,
      children: { "path" => VocabularyFakeBuiltin.new },
    )

    Expect
    vocabulary.admit(VocabularyFakeBuiltin.new, path: ["plain"], args: ["--help"]) == ["--help"]
    vocabulary.admit(group, path: ["deps"], args: ["-h"]) == ["-h"]
  end

  test "admit refuses a flag outside the vocabulary, naming it and the node" do
    Given "a builtin declaring --blank and --org, at plan new"
    vocabulary = Dev::Cli::FlagVocabulary.new
    command = VocabularyFakeBuiltin.new(flags: [Dev::Cli::Flag.new("--blank"), Dev::Cli::Flag.new("--org")])

    When "admitting a typo'd flag after a positional"
    error = assert_raises(Dev::Cli::FlagVocabulary::UnknownFlagError) do
      vocabulary.admit(command, path: ["plan", "new"], args: ["Carve system", "--hlep"])
    end

    Then "the error carries the token as typed, the path and the node, and reads as a usage error"
    error.flag == "--hlep"
    error.path == ["plan", "new"]
    error.command == command
    error.message == "unknown flag '--hlep' for 'dev plan new'"
  end

  test "admit refuses an undeclared value-flag by its name" do
    Given "a builtin declaring --keep"
    vocabulary = Dev::Cli::FlagVocabulary.new
    command = VocabularyFakeBuiltin.new(flags: [Dev::Cli::Flag.new("--keep", takes_value: true)])

    When "admitting an undeclared flag in the inline form"
    vocabulary.admit(command, path: ["cache", "gc"], args: ["--kep=3"])

    Then
    raises Dev::Cli::FlagVocabulary::UnknownFlagError
  end

  test "admit refuses at the root too: the message names bare dev" do
    Given "a root group"
    vocabulary = Dev::Cli::FlagVocabulary.new
    root = Dev::CommandGroup.root(desc: "commands", children: { "up" => VocabularyFakeBuiltin.new })

    When "admitting a flag the root does not know"
    error = assert_raises(Dev::Cli::FlagVocabulary::UnknownFlagError) { vocabulary.admit(root, path: [], args: ["--bogus"]) }

    Then
    error.message == "unknown flag '--bogus' for 'dev'"
  end

  test "admit forwards an opaque node's args verbatim: foreign flags, help flags, terminator and all" do
    Given "a project command and an opaque builtin"
    vocabulary = Dev::Cli::FlagVocabulary.new
    project = Dev::ProjectCommand.new(run: "./bin/test.sh")
    opaque = VocabularyFakeBuiltin.new(opaque_args: true)
    args = ["--fast", "--help", "--", "-h"]

    Expect
    vocabulary.admit(project, path: ["test"], args: args) == args
    vocabulary.admit(opaque, path: ["complete"], args: args) == args
  end

  test "admit treats the override of a builtin as the project's: opaque" do
    Given "a project run on a builtin's slot, the builtin declaring nothing"
    vocabulary = Dev::Cli::FlagVocabulary.new
    overridden = Dev::OverriddenCommand.new(
      builtin: VocabularyFakeBuiltin.new, project: Dev::ProjectCommand.new(run: "./bin/up.sh"),
    )

    Expect
    vocabulary.admit(overridden, path: ["up"], args: ["--anything"]) == ["--anything"]
  end
end

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

  test "parse reads a declared switch, a value flag in either form, a repeatable one, and the positionals" do
    Given "a builtin declaring --keep (value), --group (value) and --tool-caches (switch)"
    vocabulary = Dev::Cli::FlagVocabulary.new
    command = VocabularyFakeBuiltin.new(flags: [
      Dev::Cli::Flag.new("--keep", takes_value: true),
      Dev::Cli::Flag.new("--group", takes_value: true),
      Dev::Cli::Flag.new("--tool-caches"),
    ])

    When "parsing a mix, with the terminator guarding a flag-shaped positional"
    args = vocabulary.parse(
      command, path: ["cache", "gc"],
      args: ["--tool-caches", "--keep", "3", "--group=a", "x", "--group", "b", "--", "--bogus", "--"],
    )

    Then "every axis is read, and the words are kept as typed"
    args.flag?("--tool-caches")
    args.value("--keep") == "3"
    args.values("--group") == ["a", "b"]
    args.positionals == ["x", "--bogus", "--"]
    args.words == ["--tool-caches", "--keep", "3", "--group=a", "x", "--group", "b", "--", "--bogus", "--"]
  end

  test "a value flag consumes the next token whatever its shape: #{args.inspect}" do
    Given "a builtin declaring --labels (value)"
    vocabulary = Dev::Cli::FlagVocabulary.new
    command = VocabularyFakeBuiltin.new(flags: [Dev::Cli::Flag.new("--labels", takes_value: true)])

    Expect "the value is the value, not an unknown flag"
    vocabulary.parse(command, path: ["runner", "register"], args: args).value("--labels") == expected

    Where
    args                 | expected
    ["--labels", "-x"]   | "-x"
    ["--labels", "--"]   | "--"
    ["--labels", "-"]    | "-"
    ["--labels=-x"]      | "-x"
    ["--labels", "a,b"]  | "a,b"
  end

  test "parse with nothing to parse is empty" do
    Expect
    Dev::Cli::FlagVocabulary.new.parse(VocabularyFakeBuiltin.new, path: ["plain"], args: []) == Dev::Cli::ParsedArgs.new
  end

  test "parse accepts the help flags at every node as switches: they are in every vocabulary" do
    Given "a builtin declaring nothing and a group"
    vocabulary = Dev::Cli::FlagVocabulary.new
    group = Dev::CommandGroup.new(
      path: ["deps"], desc: "deps", category: Dev::Command::Category::Lifecycle,
      children: { "path" => VocabularyFakeBuiltin.new },
    )

    Expect
    vocabulary.parse(VocabularyFakeBuiltin.new, path: ["plain"], args: ["--help"]).flag?("--help")
    vocabulary.parse(group, path: ["deps"], args: ["-h"]).flag?("-h")
  end

  test "parse refuses a flag outside the vocabulary, naming it and the node" do
    Given "a builtin declaring --blank and --org, at plan new"
    vocabulary = Dev::Cli::FlagVocabulary.new
    command = VocabularyFakeBuiltin.new(flags: [Dev::Cli::Flag.new("--blank"), Dev::Cli::Flag.new("--org")])

    When "parsing a typo'd flag after a positional"
    error = assert_raises(Dev::Cli::FlagVocabulary::UnknownFlagError) do
      vocabulary.parse(command, path: ["plan", "new"], args: ["Carve system", "--hlep"])
    end

    Then "the error carries the token as typed, the path and the node, and reads as a usage error"
    error.is_a?(Dev::Cli::FlagVocabulary::UsageError)
    error.flag == "--hlep"
    error.path == ["plan", "new"]
    error.command == command
    error.message == "unknown flag '--hlep' for 'dev plan new'"
  end

  test "parse refuses an undeclared value-flag by its name" do
    Given "a builtin declaring --keep"
    vocabulary = Dev::Cli::FlagVocabulary.new
    command = VocabularyFakeBuiltin.new(flags: [Dev::Cli::Flag.new("--keep", takes_value: true)])

    When "parsing an undeclared flag in the inline form"
    vocabulary.parse(command, path: ["cache", "gc"], args: ["--kep=3"])

    Then
    raises Dev::Cli::FlagVocabulary::UnknownFlagError
  end

  test "parse refuses a value flag with nothing after it" do
    Given "a builtin declaring --keep (value)"
    vocabulary = Dev::Cli::FlagVocabulary.new
    command = VocabularyFakeBuiltin.new(flags: [Dev::Cli::Flag.new("--keep", takes_value: true)])

    When "parsing the flag as the last token"
    error = assert_raises(Dev::Cli::FlagVocabulary::MissingFlagValueError) do
      vocabulary.parse(command, path: ["cache", "gc"], args: ["--keep"])
    end

    Then
    error.is_a?(Dev::Cli::FlagVocabulary::UsageError)
    error.message == "flag '--keep' needs a value for 'dev cache gc'"
  end

  test "parse refuses a value on a switch" do
    Given "a builtin declaring --org (switch)"
    vocabulary = Dev::Cli::FlagVocabulary.new
    command = VocabularyFakeBuiltin.new(flags: [Dev::Cli::Flag.new("--org")])

    When "parsing it with an inline value"
    error = assert_raises(Dev::Cli::FlagVocabulary::UnexpectedFlagValueError) do
      vocabulary.parse(command, path: ["plan", "new"], args: ["--org=yes"])
    end

    Then
    error.is_a?(Dev::Cli::FlagVocabulary::UsageError)
    error.message == "flag '--org' takes no value for 'dev plan new'"
  end

  test "parse refuses at the root too: the message names bare dev" do
    Given "a root group"
    vocabulary = Dev::Cli::FlagVocabulary.new
    root = Dev::CommandGroup.root(desc: "commands", children: { "up" => VocabularyFakeBuiltin.new })

    When "parsing a flag the root does not know"
    error = assert_raises(Dev::Cli::FlagVocabulary::UnknownFlagError) { vocabulary.parse(root, path: [], args: ["--bogus"]) }

    Then
    error.message == "unknown flag '--bogus' for 'dev'"
  end

  test "parse forwards an opaque node's words verbatim: foreign flags, help flags, terminator and all" do
    Given "a project command and an opaque builtin"
    vocabulary = Dev::Cli::FlagVocabulary.new
    project = Dev::ProjectCommand.new(run: "./bin/test.sh")
    opaque = VocabularyFakeBuiltin.new(opaque_args: true)
    words = ["--fast", "--help", "--", "-h"]

    Expect "the words, as the positionals too — nothing is interpreted"
    vocabulary.parse(project, path: ["test"], args: words) == Dev::Cli::ParsedArgs.new(words: words, positionals: words)
    vocabulary.parse(opaque, path: ["complete"], args: words) == Dev::Cli::ParsedArgs.new(words: words, positionals: words)
  end

  test "parse treats the override of a builtin as the project's: opaque" do
    Given "a project run on a builtin's slot, the builtin declaring nothing"
    vocabulary = Dev::Cli::FlagVocabulary.new
    overridden = Dev::OverriddenCommand.new(
      builtin: VocabularyFakeBuiltin.new, project: Dev::ProjectCommand.new(run: "./bin/up.sh"),
    )

    Expect
    vocabulary.parse(overridden, path: ["up"], args: ["--anything"]).words == ["--anything"]
  end
end

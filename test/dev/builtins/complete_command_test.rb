# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/complete_command"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::CompleteCommandTest < Minitest::Test
  include SorbetHelper

  # A builtin with only the traits the tree walk reads; `completions:` is a
  # proc over the remaining words, for a leaf that completes its arguments.
  class FakeBuiltin < Dev::BuiltinCommand
    def initialize(hidden: false, completions: nil)
      super()
      @hidden = hidden
      @completions = completions
    end

    def desc = "a leaf"
    def category = Dev::Command::Category::Workflow
    def hidden? = @hidden
    def call(args:, context:); end

    def completions(words)
      @completions ? @completions.call(words) : super
    end
  end

  test "a command's argument completions default to none" do
    Given "a leaf that declares nothing"
    leaf = FakeBuiltin.new

    Expect
    leaf.completions([]) == []
    leaf.completions(["anything"]) == []
  end

  test "an overridden builtin completes with the slot's completions — the trait belongs to the builtin" do
    Given "a project command over a builtin that completes its argument"
    builtin = FakeBuiltin.new(completions: ->(_words) { %w[one two] })
    overridden = Dev::OverriddenCommand.new(builtin: builtin, project: Dev::ProjectCommand.new(run: "echo"))

    Expect
    overridden.completions([]) == %w[one two]
  end

  test "a leaf's own completions are printed when the walk ends on it — in the leaf's order, never re-sorted (#211)" do
    Given "a tree with a leaf that completes its argument from a deliberately unsorted list, recording the words it saw"
    seen = []
    leaf = FakeBuiltin.new(completions: ->(words) {
      seen << words
      %w[zeta alpha mid]
    })
    tree = {
      "up" => FakeBuiltin.new,
      "runner" => Dev::CommandGroup.new(
        path: ["runner"], desc: "r", category: Dev::Command::Category::Lifecycle,
        children: { "unregister" => leaf, "status" => FakeBuiltin.new },
      ),
    }
    root = Dev::CommandGroup.root(desc: "dev", children: tree)
    out = StringIO.new
    command = Dev::Builtins::CompleteCommand.new(root_provider: -> { root }, out: out)

    When "completing at the leaf, then one argument in"
    command.call(args: %w[runner unregister], context: Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui)))
    first = out.string.lines.map(&:chomp)
    out.truncate(0)
    out.rewind
    command.call(args: %w[runner unregister --yes], context: Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui)))
    second = out.string.lines.map(&:chomp)

    Then "the leaf's order is the printed order; the leaf sees only the words after its own name"
    first == %w[zeta alpha mid]
    second == %w[zeta alpha mid]
    seen == [[], ["--yes"]]
  end

  test "the group walk still lists child names, sorted; a leaf's arguments never leak into a group listing" do
    Given "the same tree"
    leaf = FakeBuiltin.new(completions: ->(_words) { %w[zeta alpha] })
    tree = {
      "runner" => Dev::CommandGroup.new(
        path: ["runner"], desc: "r", category: Dev::Command::Category::Lifecycle,
        children: { "unregister" => leaf, "status" => FakeBuiltin.new },
      ),
    }
    root = Dev::CommandGroup.root(desc: "dev", children: tree)
    out = StringIO.new
    command = Dev::Builtins::CompleteCommand.new(root_provider: -> { root }, out: out)

    When "completing at the group"
    command.call(args: ["runner"], context: Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui)))

    Then
    out.string.lines.map(&:chomp) == %w[status unregister]
  end

  test "traits: hidden plumbing, staleness-exempt, never stamps" do
    Given "the builtin"
    command = Dev::Builtins::CompleteCommand.new(root_provider: -> { FakeBuiltin.new }, out: StringIO.new)

    Expect "the declarative traits"
    command.hidden? == true
    command.staleness_exempt? == true
    command.stamps? == false
    command.category == Dev::Command::Category::Workflow
  end

  test "given #{words.inspect}, the candidates are #{expected.inspect}" do
    Given "a tree: leaves, a group, a runnable command with children, and hidden nodes at both levels"
    tree = {
      "up" => FakeBuiltin.new,
      "help" => FakeBuiltin.new,
      "secret" => FakeBuiltin.new(hidden: true),
      "deps" => Dev::CommandGroup.new(
        path: ["deps"], desc: "d", category: Dev::Command::Category::Lifecycle,
        children: { "path" => FakeBuiltin.new, "plumbing" => FakeBuiltin.new(hidden: true) },
      ),
      "test" => FakeBuiltin.new.with_children({
        "unit" => FakeBuiltin.new,
        "e2e" => Dev::CommandGroup.new(
          path: %w[test e2e], desc: "e", category: Dev::Command::Category::Project,
          children: { "smoke" => FakeBuiltin.new },
        ),
      }),
    }
    root = Dev::CommandGroup.root(desc: "dev", children: tree)
    out = StringIO.new
    command = Dev::Builtins::CompleteCommand.new(root_provider: -> { root }, out: out)

    When "completing after the words typed so far"
    command.call(args: words, context: Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui)))

    Then "one visible child name per line, sorted"
    out.string.lines.map(&:chomp) == expected

    Where
    words            | expected
    []               | %w[deps help test up]
    ["deps"]         | ["path"]
    ["test"]         | %w[e2e unit]
    %w[test e2e]     | ["smoke"]
    ["up"]           | []
    ["deps", "path"] | []
    ["bogus"]        | []
    %w[test bogus]   | []
  end
end

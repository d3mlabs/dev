# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/complete_command"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::CompleteCommandTest < Minitest::Test
  include SorbetHelper

  # A builtin with only the traits the tree walk reads.
  class FakeBuiltin < Dev::BuiltinCommand
    def initialize(hidden: false)
      super()
      @hidden = hidden
    end

    def desc = "a leaf"
    def category = Dev::Command::Category::Workflow
    def hidden? = @hidden
    def call(args:, context:); end
  end

  test "traits: hidden plumbing, staleness-exempt, never stamps" do
    Given "the builtin"
    command = Dev::Builtins::CompleteCommand.new(commands_provider: -> { {} }, out: StringIO.new)

    Expect "the declarative traits"
    command.hidden? == true
    command.staleness_exempt? == true
    command.stamps? == false
    command.category == Dev::Command::Category::Workflow
  end

  test "given #{words.inspect}, the candidates are #{expected.inspect}" do
    Given "a tree: leaves, a pure group, a runnable group, and hidden nodes at both levels"
    tree = {
      "up" => FakeBuiltin.new,
      "help" => FakeBuiltin.new,
      "secret" => FakeBuiltin.new(hidden: true),
      "deps" => Dev::CommandGroup.new(
        path: ["deps"], desc: "d", category: Dev::Command::Category::Lifecycle,
        children: { "path" => FakeBuiltin.new, "plumbing" => FakeBuiltin.new(hidden: true) },
      ),
      "test" => Dev::CommandGroup.new(
        path: ["test"], desc: "t", category: Dev::Command::Category::Project, own: FakeBuiltin.new,
        children: {
          "unit" => FakeBuiltin.new,
          "e2e" => Dev::CommandGroup.new(
            path: %w[test e2e], desc: "e", category: Dev::Command::Category::Project,
            children: { "smoke" => FakeBuiltin.new },
          ),
        },
      ),
    }
    out = StringIO.new
    command = Dev::Builtins::CompleteCommand.new(commands_provider: -> { tree }, out: out)

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

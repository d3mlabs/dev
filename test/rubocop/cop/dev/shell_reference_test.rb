# typed: false
# frozen_string_literal: true

require "test_helper"
require "rubocop"
require File.expand_path("../../../../rubocop/cop/dev/shell_reference", __dir__)

# The one layering rule, held by the gate (ADR-0014, dev#537): a feature or
# the vocabulary under lib/dev may not reference the shell's constants.
transform!(RSpock::AST::Transformation)
class RuboCop::Cop::Dev::ShellReferenceTest < Minitest::Test
  ROOT = File.expand_path("../../../..", __dir__)

  # The cop run over one source as if it sat at `path` under the repo.
  def offenses(source, path)
    config = RuboCop::Config.new({ "Dev/ShellReference" => { "Enabled" => true } }, File.join(ROOT, ".rubocop.yml"))
    cop = RuboCop::Cop::Dev::ShellReference.new(config)
    processed = RuboCop::ProcessedSource.new(source, 3.1, File.join(ROOT, path))
    RuboCop::Cop::Commissioner.new([cop], [], raise_error: true).investigate(processed).offenses
  end

  test "a feature under lib/dev that references the shell is an offense, in every spelling Ruby lets through: #{spelling}" do
    When
    found = offenses(source, "lib/dev/operator_access.rb")

    Then "one offense, at the reference, naming the shell constant and the rule"
    found.map { |o| [o.line, o.message] } == [[line, "`#{constant}` is the shell's (`Dev::Cli`); a feature or the vocabulary under lib/dev may not reference it (ADR-0014)."]]

    Where
    spelling                | source                                                                                             | line | constant
    "a call"                | "module Dev\n  class Foo\n    def go = Dev::Cli::Runner.new\n  end\nend\n"                         | 3    | "Dev::Cli::Runner"
    "cbase-anchored"        | "module Dev\n  class Foo\n    def go = ::Dev::Cli::Runner.new\n  end\nend\n"                       | 3    | "Dev::Cli::Runner"
    "a sig"                 | "module Dev\n  class Foo\n    sig { params(ui: Dev::Cli::UiImpl).void }\n  end\nend\n"             | 3    | "Dev::Cli::UiImpl"
    "a T.let"               | "module Dev\n  class Foo\n    X = T.let(nil, T.nilable(Dev::Cli::ExecutionContext))\n  end\nend\n" | 3    | "Dev::Cli::ExecutionContext"
    "a deeper path, once"   | "module Dev\n  class Foo\n    K = Dev::Cli::Builtins::UpCommand\n  end\nend\n"                     | 3    | "Dev::Cli::Builtins"
    "lexically, inside Dev" | "module Dev\n  class Foo\n    def go = Cli::Runner.new\n  end\nend\n"                              | 3    | "Cli::Runner"
  end

  test "the shell may reference itself, and lib/dev.rb composes it: #{path}" do
    Expect
    offenses("module Dev\n  module Cli\n    class Foo\n      def go = Dev::Cli::Runner.new\n    end\n  end\nend\n", path).empty?

    Where
    path                                  | _
    "lib/dev/cli/command.rb"              | 0
    "lib/dev/cli/builtins/up_command.rb"  | 0
    "lib/dev/cli.rb"                      | 0
  end

  test "outside lib/dev the cop has no opinion — tests and the bootstrap files name the shell freely: #{path}" do
    Expect
    offenses("x = Dev::Cli::Runner.new\n", path).empty?

    Where
    path                                  | _
    "test/dev/cli/runner_test.rb"         | 0
    "test/support/answering_ui.rb"        | 0
    "lib/ensure_bundler.rb"               | 0
    "bin/dev"                             | 0
  end

  test "a comment is prose, not a reference; Dev::Cli alone and the rest of Dev are not the shell's constants" do
    Given
    source = <<~RUBY
      module Dev
        # Dev::Cli::UiImpl is the cli-ui tier; the choice is bin/dev's.
        class Foo
          sig { params(ui: Dev::Ui, cli: ::Dev::Cli).void }
          def initialize(ui:, cli:) = nil
        end
      end
    RUBY

    Expect
    offenses(source, "lib/dev/ui.rb").empty?
  end
end

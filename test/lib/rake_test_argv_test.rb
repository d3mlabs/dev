# typed: false
# frozen_string_literal: true

require "test_helper"
require "rake_test_argv"

transform!(RSpock::AST::Transformation)
class RakeTestArgvTest < Minitest::Test
  test "rake_test_argv runs the full suite when no files are requested" do
    When "building the argv with no requested files"
    argv = rake_test_argv([])

    Then "it is the bare rake test invocation"
    argv == ["bundle", "exec", "rake", "test"]
  end

  test "rake_test_argv scopes the run to a single requested file via TEST" do
    When "building the argv with one requested file"
    argv = rake_test_argv(["test/dev/command_parser_test.rb"])

    Then "TEST is the file itself"
    argv == ["bundle", "exec", "rake", "test", "TEST=test/dev/command_parser_test.rb"]
  end

  test "rake_test_argv joins multiple requested files into one brace glob" do
    When "building the argv with two requested files"
    argv = rake_test_argv(["test/dev/command_parser_test.rb", "test/lib/ensure_bundler_test.rb"])

    Then "TEST is a single brace glob over both files"
    argv == ["bundle", "exec", "rake", "test", "TEST={test/dev/command_parser_test.rb,test/lib/ensure_bundler_test.rb}"]
  end

  test "rake_test_argv does not mutate its input" do
    Given "a requested files array"
    requested = ["test/dev/command_parser_test.rb"]

    When "building the argv"
    rake_test_argv(requested)

    Then "the input array is unchanged"
    requested == ["test/dev/command_parser_test.rb"]
  end
end

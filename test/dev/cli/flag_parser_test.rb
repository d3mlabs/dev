# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/flag_parser"

transform!(RSpock::AST::Transformation)
class Dev::Cli::FlagParserTest < Minitest::Test
  test "value reads the space-separated form" do
    Given "the parser"
    parser = Dev::Cli::FlagParser.new

    Expect "the value after the flag"
    parser.value(["gc", "--keep", "5"], "--keep") == "5"
  end

  test "value reads the inline --flag=value form" do
    Given "the parser"
    parser = Dev::Cli::FlagParser.new

    Expect "the value after the equals sign, split once"
    parser.value(["--labels=macos,ue-editor"], "--labels") == "macos,ue-editor"
    parser.value(["--dir=~/runner=weird"], "--dir") == "~/runner=weird"
  end

  test "value is nil when the flag is absent or valueless" do
    Given "the parser"
    parser = Dev::Cli::FlagParser.new

    Expect "no value to read"
    parser.value(["gc"], "--keep").nil?
    parser.value(["gc", "--keep"], "--keep").nil?
    parser.value([], "--keep").nil?
  end
end

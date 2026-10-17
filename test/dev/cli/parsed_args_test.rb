# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/parsed_args"

transform!(RSpock::AST::Transformation)
class Dev::Cli::ParsedArgsTest < Minitest::Test
  test "reads a switch, a value flag (last wins), a repeatable flag, and the positionals" do
    Given "args as the parser would build them"
    args = Dev::Cli::ParsedArgs.new(
      words: ["--org", "--keep", "3", "--keep=5", "--group", "a", "--group", "b", "title"],
      positionals: ["title"],
      switches: ["--org"],
      values: { "--keep" => ["3", "5"], "--group" => ["a", "b"] },
    )

    Expect
    args.flag?("--org")
    args.flag?("--keep")
    !args.flag?("--blank")
    args.value("--keep") == "5"
    args.value("--blank").nil?
    args.values("--group") == ["a", "b"]
    args.values("--blank") == []
    args.positionals == ["title"]
    args.words.first == "--org"
  end

  test "the no-argument default is empty on every axis" do
    Expect
    Dev::Cli::ParsedArgs.new.positionals.empty?
    Dev::Cli::ParsedArgs.new.words.empty?
    !Dev::Cli::ParsedArgs.new.flag?("--org")
  end

  test "equality is by value, on every axis" do
    Expect
    Dev::Cli::ParsedArgs.new(positionals: ["a"], switches: ["--x"]) ==
      Dev::Cli::ParsedArgs.new(positionals: ["a"], switches: ["--x"])
    Dev::Cli::ParsedArgs.new(positionals: ["a"]) != Dev::Cli::ParsedArgs.new(positionals: ["b"])
    Dev::Cli::ParsedArgs.new(switches: ["--x"]) != Dev::Cli::ParsedArgs.new
    Dev::Cli::ParsedArgs.new(values: { "--k" => ["1"] }) != Dev::Cli::ParsedArgs.new
    Dev::Cli::ParsedArgs.new(words: ["--"]) != Dev::Cli::ParsedArgs.new
    Dev::Cli::ParsedArgs.new(positionals: ["a"]).hash == Dev::Cli::ParsedArgs.new(positionals: ["a"]).hash
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/command"

transform!(RSpock::AST::Transformation)
class CommandTest < Minitest::Test
  extend T::Sig

  test "initialize with only run uses default desc and pretty_ui" do
    Given "we build a Command with only run"
    cmd = Dev::Command.new(run: "./bin/setup.rb")

    Expect "desc and pretty_ui have defaults"
    cmd.run == "./bin/setup.rb"
    cmd.desc == "(no description)"
    cmd.pretty_ui == true
  end

  test "initialize with all args stores them" do
    Given "we build a Command with run, desc, and pretty_ui"
    cmd = Dev::Command.new(
      run: "./bin/test.rb",
      desc: "Run tests",
      pretty_ui: true
    )

    Expect "all attributes match"
    cmd.run == "./bin/test.rb"
    cmd.desc == "Run tests"
    cmd.pretty_ui == true
  end

  test "pretty_ui can be false explicitly" do
    Given "we build a Command with pretty_ui: false"
    cmd = Dev::Command.new(run: "./bin/foo.rb", pretty_ui: false)

    Expect "pretty_ui is false"
    cmd.pretty_ui == false
  end

  test "#== returns #{expected} for #{cmd1} vs #{cmd2}" do
    Given "we compare the two commands"
    result = (cmd1 == cmd2)

    Expect "the result matches"
    result == expected

    Where
    cmd1                                                      | cmd2                                                      | expected
    Dev::Command.new(run: "r1", desc: "d1", pretty_ui: false) | Dev::Command.new(run: "r1", desc: "d1", pretty_ui: false) | true
    Dev::Command.new(run: "r1", desc: "d1", pretty_ui: false) | Dev::Command.new(run: "r1", desc: "d1", pretty_ui: true)  | false
    Dev::Command.new(run: "r1", desc: "d1", pretty_ui: false) | Dev::Command.new(run: "r1", desc: "d2", pretty_ui: false) | false
    Dev::Command.new(run: "r1", desc: "d1", pretty_ui: false) | Dev::Command.new(run: "r2", desc: "d1", pretty_ui: false) | false
    Dev::Command.new(run: "r1", desc: "d1", pretty_ui: false) | "not a command"                                           | false
    Dev::Command.new(run: "r1", desc: "d1", pretty_ui: false) | nil                                                       | false
  end

  test "#eql? returns #{expected} for #{other}" do
    Given "a reference command"
    cmd = Dev::Command.new(run: "r1", desc: "d1", pretty_ui: false)

    Expect "eql? returns the expected result"
    cmd.eql?(other) == expected

    Where
    other                                                     | expected
    Dev::Command.new(run: "r1", desc: "d1", pretty_ui: false) | true
    Dev::Command.new(run: "r1", desc: "d1", pretty_ui: true)  | false
    Dev::Command.new(run: "r1", desc: "d2", pretty_ui: false) | false
    Dev::Command.new(run: "r2", desc: "d1", pretty_ui: false) | false
    "not a command"                                           | false
    nil                                                       | false
  end

  test "#hash equality is #{expected} for #{cmd1} vs #{cmd2}" do
    Given "we compare hashes of the two commands"
    result = (cmd1.hash == cmd2.hash)

    Expect "hash equality matches"
    result == expected

    Where
    cmd1                                                      | cmd2                                                      | expected
    Dev::Command.new(run: "r1", desc: "d1", pretty_ui: false) | Dev::Command.new(run: "r1", desc: "d1", pretty_ui: false) | true
    Dev::Command.new(run: "r1", desc: "d1", pretty_ui: false) | Dev::Command.new(run: "r1", desc: "d1", pretty_ui: true)  | false
    Dev::Command.new(run: "r1", desc: "d1", pretty_ui: false) | Dev::Command.new(run: "r1", desc: "d2", pretty_ui: false) | false
    Dev::Command.new(run: "r1", desc: "d1", pretty_ui: false) | Dev::Command.new(run: "r2", desc: "d1", pretty_ui: false) | false
  end
end

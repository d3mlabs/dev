# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/command"

transform!(RSpock::AST::Transformation)
class CommandTest < Minitest::Test
  extend T::Sig

  test "initialize with only run uses default desc and repl" do
    Given "we build a Command with only run"
    cmd = Dev::Command.new(run: "./bin/setup.rb")

    Expect "desc and repl have defaults"
    cmd.run == "./bin/setup.rb"
    cmd.desc == "(no description)"
    cmd.repl == false
  end

  test "initialize with all args stores them" do
    Given "we build a Command with run, desc, and repl"
    cmd = Dev::Command.new(
      run: "./bin/test.rb",
      desc: "Run tests",
      repl: false
    )

    Expect "all attributes match"
    cmd.run == "./bin/test.rb"
    cmd.desc == "Run tests"
    cmd.repl == false
  end

  test "repl can be true explicitly" do
    Given "we build a Command with repl: true"
    cmd = Dev::Command.new(run: "./bin/foo.rb", repl: true)

    Expect "repl is true"
    cmd.repl == true
  end

  test "#== returns #{expected} for #{cmd1} vs #{cmd2}" do
    Given "we compare the two commands"
    result = (cmd1 == cmd2)

    Expect "the result matches"
    result == expected

    Where
    cmd1                                                  | cmd2                                                  | expected
    Dev::Command.new(run: "r1", desc: "d1", repl: false) | Dev::Command.new(run: "r1", desc: "d1", repl: false) | true
    Dev::Command.new(run: "r1", desc: "d1", repl: false) | Dev::Command.new(run: "r1", desc: "d1", repl: true)  | false
    Dev::Command.new(run: "r1", desc: "d1", repl: false) | Dev::Command.new(run: "r1", desc: "d2", repl: false) | false
    Dev::Command.new(run: "r1", desc: "d1", repl: false) | Dev::Command.new(run: "r2", desc: "d1", repl: false) | false
    Dev::Command.new(run: "r1", desc: "d1", repl: false) | "not a command"                                      | false
    Dev::Command.new(run: "r1", desc: "d1", repl: false) | nil                                                  | false
  end

  test "#eql? returns #{expected} for #{other}" do
    Given "a reference command"
    cmd = Dev::Command.new(run: "r1", desc: "d1", repl: false)

    Expect "eql? returns the expected result"
    cmd.eql?(other) == expected

    Where
    other                                                 | expected
    Dev::Command.new(run: "r1", desc: "d1", repl: false) | true
    Dev::Command.new(run: "r1", desc: "d1", repl: true)  | false
    Dev::Command.new(run: "r1", desc: "d2", repl: false) | false
    Dev::Command.new(run: "r2", desc: "d1", repl: false) | false
    "not a command"                                       | false
    nil                                                   | false
  end

  test "#hash equality is #{expected} for #{cmd1} vs #{cmd2}" do
    Given "we compare hashes of the two commands"
    result = (cmd1.hash == cmd2.hash)

    Expect "hash equality matches"
    result == expected

    Where
    cmd1                                                  | cmd2                                                  | expected
    Dev::Command.new(run: "r1", desc: "d1", repl: false) | Dev::Command.new(run: "r1", desc: "d1", repl: false) | true
    Dev::Command.new(run: "r1", desc: "d1", repl: false) | Dev::Command.new(run: "r1", desc: "d1", repl: true)  | false
    Dev::Command.new(run: "r1", desc: "d1", repl: false) | Dev::Command.new(run: "r1", desc: "d2", repl: false) | false
    Dev::Command.new(run: "r1", desc: "d1", repl: false) | Dev::Command.new(run: "r2", desc: "d1", repl: false) | false
  end
end

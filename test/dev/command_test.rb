# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/command"

transform!(RSpock::AST::Transformation)
class CommandTest < Minitest::Test
  extend T::Sig

  test "initialize with only run uses default desc and interactive" do
    Given "we build a Command with only run"
    cmd = Dev::Command.new(run: "./bin/setup.rb")

    Then "desc and interactive have defaults"
    assert_equal "./bin/setup.rb", cmd.run
    assert_equal "(no description)", cmd.desc
    assert_equal false, cmd.interactive
  end

  test "initialize with all args stores them" do
    Given "we build a Command with run, desc, and interactive"
    cmd = Dev::Command.new(
      run: "rspec",
      desc: "Run tests",
      interactive: true
    )

    Then "all attributes match"
    assert_equal "rspec", cmd.run
    assert_equal "Run tests", cmd.desc
    assert_equal true, cmd.interactive
  end

  test "interactive can be false explicitly" do
    Given "we build a Command with interactive: false"
    cmd = Dev::Command.new(run: "./bin/foo.rb", interactive: false)

    Then "interactive is false"
    assert_equal false, cmd.interactive
  end

  test "#== for #{cmd1} and #{cmd2} returns #{expected}" do
    Expect "the correct result"
    cmd1.==(cmd2) == expected

    Where
    cmd1                                                        | cmd2                                                        | expected
    Dev::Command.new(run: "r1", desc: "d1", interactive: false) | Dev::Command.new(run: "r1", desc: "d1", interactive: false) | true
    Dev::Command.new(run: "r1", desc: "d1", interactive: false) | Dev::Command.new(run: "r1", desc: "d1", interactive: true)  | false
    Dev::Command.new(run: "r1", desc: "d1", interactive: false) | Dev::Command.new(run: "r1", desc: "d2", interactive: false) | false
    Dev::Command.new(run: "r1", desc: "d1", interactive: false) | Dev::Command.new(run: "r2", desc: "d1", interactive: false) | false
    Dev::Command.new(run: "r1", desc: "d1", interactive: false) | "not a command"                                             | false
    Dev::Command.new(run: "r1", desc: "d1", interactive: false) | nil                                                         | false
  end

  test "Comparing #{cmd}#eql? with #{other} returns #{expected}" do
    Given "a command with run, desc, and interactive"
    cmd = Dev::Command.new(run: "r1", desc: "d1", interactive: false)

    Expect "comparing with #{other} returns: #{expected}"
    cmd1.eql?(other) == expected

    Where
    other                                                       | expected
    Dev::Command.new(run: "r1", desc: "d1", interactive: false) | true
    Dev::Command.new(run: "r1", desc: "d1", interactive: true)  | false
    Dev::Command.new(run: "r1", desc: "d2", interactive: false) | false
    Dev::Command.new(run: "r2", desc: "d1", interactive: false) | false
    "not a command"                                             | false
    nil                                                         | false
  end

  test "#hash for #{cmd1} and #{cmd2} returns #{expected}" do
    Given "a command with run, desc, and interactive"
    cmd2 = Dev::Command.new(run: "r1", desc: "d1", interactive: false)

    Expect "hashes are equal when commands are equal"
    (cmd1.hash == cmd2.hash) == expected

    Where
    cmd1                                                        | cmd2                                                        | expected
    Dev::Command.new(run: "r1", desc: "d1", interactive: false) | Dev::Command.new(run: "r1", desc: "d1", interactive: false) | true
    Dev::Command.new(run: "r1", desc: "d1", interactive: false) | Dev::Command.new(run: "r1", desc: "d1", interactive: true)  | false
    Dev::Command.new(run: "r1", desc: "d1", interactive: false) | Dev::Command.new(run: "r1", desc: "d2", interactive: false) | false
    Dev::Command.new(run: "r1", desc: "d1", interactive: false) | Dev::Command.new(run: "r2", desc: "d1", interactive: false) | false
  end
end

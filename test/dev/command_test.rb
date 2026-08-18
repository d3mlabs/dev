# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/command"

# A minimal builtin for exercising the trait defaults, the hierarchy's
# open edge, and the OverriddenCommand composition.
class FakeBuiltin < Dev::BuiltinCommand
  def initialize(desc: "fake builtin", hidden: false, staleness_exempt: false, stamps: false, &body)
    @desc = desc
    @hidden = hidden
    @staleness_exempt = staleness_exempt
    @stamps = stamps
    @body = body
  end

  attr_reader :desc

  def hidden? = @hidden

  def staleness_exempt? = @staleness_exempt

  def stamps? = @stamps

  def call(args:, context:)
    @body&.call(args, context)
  end
end unless defined?(FakeBuiltin)

transform!(RSpock::AST::Transformation)
class CommandTest < Minitest::Test
  extend T::Sig
  include SorbetHelper

  test "initialize with only run uses default desc and repl" do
    Given "we build a ProjectCommand with only run"
    cmd = Dev::ProjectCommand.new(run: "./bin/setup.rb")

    Expect "desc and repl have defaults"
    cmd.run == "./bin/setup.rb"
    cmd.desc == "(no description)"
    cmd.repl == false
  end

  test "initialize with all args stores them" do
    Given "we build a ProjectCommand with run, desc, and repl"
    cmd = Dev::ProjectCommand.new(
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
    Given "we build a ProjectCommand with repl: true"
    cmd = Dev::ProjectCommand.new(run: "./bin/foo.rb", repl: true)

    Expect "repl is true"
    cmd.repl == true
  end

  test "container defaults to true" do
    Given "a ProjectCommand without explicit container"
    cmd = Dev::ProjectCommand.new(run: "./bin/build.sh")

    Expect
    cmd.container == true
  end

  test "container can be set to false" do
    Given "a ProjectCommand with container: false"
    cmd = Dev::ProjectCommand.new(run: "./bin/deploy.sh", container: false)

    Expect
    cmd.container == false
  end

  test "a ProjectCommand never guards, stamps, or hides by default" do
    Given "a plain ProjectCommand"
    cmd = Dev::ProjectCommand.new(run: "./bin/test.sh")

    Expect "the Command base defaults hold"
    !cmd.hidden?
    !cmd.staleness_exempt?
    !cmd.stamps?
  end

  test "hidden: true marks a ProjectCommand hidden" do
    Given "a ProjectCommand with hidden: true"
    cmd = Dev::ProjectCommand.new(run: "./bin/plumbing.sh", hidden: true)

    Expect
    cmd.hidden?
  end

  test "a builtin without trait overrides gets the Command defaults" do
    Given "a builtin defining only desc and call"
    builtin = Class.new(Dev::BuiltinCommand) do
      def desc = "minimal"

      def call(args:, context:); end
    end.new

    Expect "the Command trait defaults hold"
    !builtin.hidden?
    !builtin.staleness_exempt?
    !builtin.stamps?
  end

  test "subclassing BuiltinCommand is the hierarchy's declared open edge" do
    Given "a builtin subclass"
    builtin = FakeBuiltin.new(desc: "open edge")

    Expect "it enters the sealed hierarchy through the BuiltinCommand variant"
    builtin.is_a?(Dev::BuiltinCommand)
    builtin.is_a?(Dev::Command)
    builtin.desc == "open edge"
  end

  test "including Command directly raises: the seal admits only its three declared variants" do
    When "including the sealed module outside its declaring file"
    Class.new { include Dev::Command }

    Then "sorbet-runtime rejects the include"
    raises RuntimeError
  end

  test "ProjectCommand is final: subclassing raises, keeping descent closed" do
    When "declaring a subclass of the data leaf"
    Class.new(Dev::ProjectCommand)

    Then "sorbet-runtime rejects the open edge"
    raises RuntimeError
  end

  test "OverriddenCommand is final: subclassing raises, keeping descent closed" do
    When "declaring a subclass of the data leaf"
    Class.new(Dev::OverriddenCommand)

    Then "sorbet-runtime rejects the open edge"
    raises RuntimeError
  end

  test "an OverriddenCommand takes desc and hidden from the project override" do
    Given "a builtin slot overridden by a hidden project command"
    builtin = FakeBuiltin.new(desc: "builtin up")
    project = Dev::ProjectCommand.new(run: "./bin/up.sh", desc: "project up", hidden: true)
    cmd = Dev::OverriddenCommand.new(builtin: builtin, project: project)

    Expect "the override owns the slot, so its desc and visibility win"
    cmd.desc == "project up"
    cmd.hidden?
  end

  test "an OverriddenCommand takes guard and stamp traits from the builtin slot" do
    Given "a stamping, staleness-exempt builtin slot overridden by a project command"
    builtin = FakeBuiltin.new(staleness_exempt: true, stamps: true)
    project = Dev::ProjectCommand.new(run: "./bin/up.sh", desc: "project up")
    cmd = Dev::OverriddenCommand.new(builtin: builtin, project: project)

    Expect "the slot's traits hold: a project up: still is the provisioning command"
    cmd.staleness_exempt?
    cmd.stamps?
  end

  test "an OverriddenCommand exposes its typed halves" do
    Given "an overridden command"
    builtin = FakeBuiltin.new
    project = Dev::ProjectCommand.new(run: "./bin/up.sh")
    cmd = Dev::OverriddenCommand.new(builtin: builtin, project: project)

    Expect "both halves are reachable for the executor's dispatch"
    cmd.builtin == builtin
    cmd.project == project
  end

  test "#== returns #{expected} for #{cmd1} vs #{cmd2}" do
    Given "we compare the two commands"
    result = (cmd1 == cmd2)

    Expect "the result matches"
    result == expected

    Where
    cmd1 | cmd2 | expected
    Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false) | Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false) | true
    Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false) | Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: true)  | false
    Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false) | Dev::ProjectCommand.new(run: "r1", desc: "d2", repl: false) | false
    Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false) | Dev::ProjectCommand.new(run: "r2", desc: "d1", repl: false) | false
    Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false) | "not a command"                                              | false
    Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false) | nil                                                          | false
  end

  test "#== considers container field" do
    Given "two commands differing only in container"
    a = Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false, container: true)
    b = Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false, container: false)

    Expect
    a != b
  end

  test "#eql? returns #{expected} for #{other}" do
    Given "a reference command"
    cmd = Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false)

    Expect "eql? returns the expected result"
    cmd.eql?(other) == expected

    Where
    other | expected
    Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false) | true
    Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: true)  | false
    Dev::ProjectCommand.new(run: "r1", desc: "d2", repl: false) | false
    Dev::ProjectCommand.new(run: "r2", desc: "d1", repl: false) | false
    "not a command"                                              | false
    nil                                                          | false
  end

  test "#hash equality is #{expected} for #{cmd1} vs #{cmd2}" do
    Given "we compare hashes of the two commands"
    result = (cmd1.hash == cmd2.hash)

    Expect "hash equality matches"
    result == expected

    Where
    cmd1 | cmd2 | expected
    Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false) | Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false) | true
    Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false) | Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: true)  | false
    Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false) | Dev::ProjectCommand.new(run: "r1", desc: "d2", repl: false) | false
    Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false) | Dev::ProjectCommand.new(run: "r2", desc: "d1", repl: false) | false
  end

  test "#hash differs when container differs" do
    Given "two commands differing only in container"
    a = Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false, container: true)
    b = Dev::ProjectCommand.new(run: "r1", desc: "d1", repl: false, container: false)

    Expect
    a.hash != b.hash
  end
end

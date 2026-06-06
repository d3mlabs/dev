# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev"
require "dev/runner"
require "stringio"
require "tempfile"

transform!(RSpock::AST::Transformation)
class RunnerTest < Minitest::Test
  extend T::Sig
  include SorbetHelper

  test "run with empty argv prints usage" do
    Given "a Runner with a dev.yml"
    runner = build_runner(commands: { "up" => { "run" => "./bin/up.rb", "desc" => "Setup" } })
    out = StringIO.new

    When "we run with empty argv"
    runner.run([], ui: fake_ui, out: out)

    Then "usage is printed"
    out.string.include?("Usage: dev <command> [args...]")
    out.string.include?("Commands for testproject:")
    out.string.include?("up")
    out.string.include?("Setup")
  end

  test "run with --help prints usage" do
    Given "a Runner"
    runner = build_runner
    out = StringIO.new

    When "we run with --help"
    runner.run(["--help"], ui: fake_ui, out: out)

    Then "usage is printed"
    out.string.include?("Usage: dev <command> [args...]")
  end

  test "run with -h prints usage" do
    Given "a Runner"
    runner = build_runner
    out = StringIO.new

    When "we run with -h"
    runner.run(["-h"], ui: fake_ui, out: out)

    Then "usage is printed"
    out.string.include?("Usage: dev <command> [args...]")
  end

  test "run with unknown command prints error to stderr and exits 1" do
    Given "a Runner"
    runner = build_runner
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).once

    When "we run an unknown command"
    runner.run(["nonexistent"], ui: fake_ui)

    Then "error mentions the command name"
    $stderr.string.include?("nonexistent")
    $stderr.string.include?("dev --help")

    Cleanup
    $stderr = old_stderr
  end

  test "usage includes built-in update-deps command" do
    Given "a Runner with no project commands"
    runner = build_runner(commands: {})
    out = StringIO.new

    When "we print usage"
    runner.run([], ui: fake_ui, out: out)

    Then "update-deps is listed"
    out.string.include?("update-deps")
    out.string.include?("Resolve dependency constraints")
  end

  test "usage includes both built-in and project commands" do
    Given "a Runner with project commands"
    runner = build_runner(commands: {
      "test" => { "run" => "rspec", "desc" => "Run tests" },
      "up" => { "run" => "./bin/up.rb", "desc" => "Setup" },
    })
    out = StringIO.new

    When "we print usage"
    runner.run([], ui: fake_ui, out: out)

    Then "all commands appear"
    out.string.include?("update-deps")
    out.string.include?("test")
    out.string.include?("up")
  end

  private

  def build_runner(name: "testproject", commands: {})
    yaml = { "name" => name, "commands" => commands }
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(YAML.dump(yaml))
    tmp.flush

    Dev::Runner.new(
      dev_yaml_path: Pathname.new(tmp.path),
      cfg_parser: Dev::ConfigParser.new(command_parser: Dev::CommandParser.new),
    )
  end

  def fake_ui
    ui = typed_mock(Dev::Cli::Ui)
    ui.stubs(:print_header)
    ui
  end
end

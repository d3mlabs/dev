# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/command"
require "dev/command_parser"
require "dev/config"
require "dev/config_parser"
require "tempfile"

transform!(RSpock::AST::Transformation)
class ConfigParserTest < Minitest::Test
  test "#parse returns Config with name and Command objects from dev.yml" do
    Given "a dev.yml file with name and commands"
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(<<~YAML)
      name: myproject
      commands:
        up:
          desc: Setup
          run: ./bin/setup.rb
        test:
          run: rspec
    YAML
    tmp.flush

    When "the config is parsed"
    parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
    config = parser.parse(Pathname.new(tmp.path))

    Then "we get the expected config"
    config.name == "myproject"
    config.command("up") == Dev::Command.new(run: "./bin/setup.rb", desc: "Setup", repl: false)
    config.command("test") == Dev::Command.new(run: "rspec", desc: "(no description)", repl: false)

    Cleanup
    tmp.close!
  end

  test "#parse raises ArgumentError when a command is missing run" do
    Given "a dev.yml file with a command without run"
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(<<~YAML)
      name: myproject
      commands:
        up:
          desc: Setup but no run
    YAML
    tmp.flush

    When "parsing the config"
    parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
    parser.parse(Pathname.new(tmp.path))

    Then "it raises ArgumentError"
    raises ArgumentError

    Cleanup
    tmp.close!
  end

  test "#parse with repl flag passes it through to Command" do
    Given "a dev.yml file with repl set"
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(<<~YAML)
      name: myproject
      commands:
        console:
          run: ./bin/console
          repl: true
    YAML
    tmp.flush

    When "the config is parsed"
    parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
    config = parser.parse(Pathname.new(tmp.path))

    Then "the command has repl true"
    config.command("console").repl == true

    Cleanup
    tmp.close!
  end

  test "#parse ignores non-command top-level keys like ruby" do
    Given "a dev.yml file with a ruby key alongside commands"
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(<<~YAML)
      name: myproject
      ruby: "4.0.1"
      commands:
        up:
          desc: Setup
          run: ./bin/setup.rb
    YAML
    tmp.flush

    When "the config is parsed"
    parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
    config = parser.parse(Pathname.new(tmp.path))

    Then "it parses successfully with the correct command"
    config.name == "myproject"
    config.command("up").run == "./bin/setup.rb"

    Cleanup
    tmp.close!
  end
end

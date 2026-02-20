# frozen_string_literal: true

require "test_helper"
require "dev/config"
require "dev/config_parser"
require "tempfile"

transform!(RSpock::AST::Transformation)
class ConfigParserTest < Minitest::Test
  test "parse returns Config with name and commands from dev.yml" do
    Given "A dev.yml file with name and commands"
    tmp_file = Tempfile.create(["dev", ".yml"])
    tmp_file.write <<~YAML
      name: dev
      commands:
        up:
          run: ./bin/setup.rb
        test:
          run: rspec
    YAML

    When "the config is parsed"
    config = parser.parse(tmp_file.path)

    Then "we get the expected result"
    config.name == "dev"
    config.commands.size == 2
    config.commands["up"] == { "run" => "./bin/setup.rb" }
    config.commands["test"] == { "run" => "rspec" }

    Cleanup "the tempfile is deleted"
    tmp_file.close!
  end

  test "parse raises when file does not exist" do
    Given "a ConfigParser"
    parser = Dev::ConfigParser.new
    
    Expect "raises Errno::ENOENT when we try to parse a nonexistent dev.yml file"
    assert_raises Errno::ENOENT do
      parser.parse("/nonexistent/dev.yml")
    end
  end

  test "parse raises when YAML is invalid" do
    Given "an invalid dev.yml file"
    tmp_file = Tempfile.create(["dev", ".yml"])
    tmp_file.write("not: valid: yaml: [")
    
    Expect "raises Psych::SyntaxError when we try to parse it"
    parser = Dev::ConfigParser.new
    assert_raises Psych::SyntaxError do
      parser.parse(tmp_file.path)
    end

    Cleanup "the tempfile is deleted"
    tmp_file.close!
  end
end

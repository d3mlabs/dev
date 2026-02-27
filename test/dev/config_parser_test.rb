# # typed: false
# # frozen_string_literal: true

# require "test_helper"
# require "dev/command"
# require "dev/command_parser"
# require "dev/config"
# require "dev/config_parser"
# require "tempfile"

# transform!(RSpock::AST::Transformation)
# class ConfigParserTest < Minitest::Test
#   test "run is required" do
#     Given "A dev.yml file with a command without a run argument"
#     tmp_file = Tempfile.new("dev.yml")
#     tmp_file.write <<~YAML
#       name: dev
#       commands:
#         up:
#           desc: Up command!
#     YAML
#     tmp_file.flush

#     Expect "parsing raises ArgumentError"
#     parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
#     assert_raises ArgumentError do
#       parser.parse(T.must(tmp_file.path))
#     end

#     Cleanup "the tempfile is deleted"
#     tmp_file. close!
#   end

#   test "description is optional and defaults to '(no description)'" do
#     Given "A dev.yml file with a command without a description"
#     tmp_file = Tempfile.new("dev.yml")
#     tmp_file.write <<~YAML
#       name: dev
#       commands:
#         up:
#           run: ./bin/setup.rb
#     YAML
#     tmp_file.flush

#     When "the config is parsed"
#     parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
#     config = parser.parse(T.must(tmp_file.path))

#     Then "description defaults to '(no description)'"
#     assert_equal "(no description)", T.must(config.command("up")).desc

#     Cleanup "the tempfile is deleted"
#     tmp_file.delete
#   end

#   test "interactive with yaml value `#{yaml_string}` is parsed properly" do
#     Given "A command with an interactive flag"
#     tmp_file = Tempfile.new("dev.yml")
#     tmp_file.write <<~YAML
#       name: dev
#       commands:
#         up:
#           run: ./bin/setup.rb
#           interactive: #{yaml_string}
#     YAML
#     tmp_file.flush

#     When "the config is parsed"
#     parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
#     config = parser.parse(T.must(tmp_file.path))

#     Then "interactive is parsed properly"
#     assert_equal parsed_value, T.must(config.command("up")).interactive

#     Cleanup "by ensuring the tempfile is deleted"
#     tmp_file.delete

#     Where
#     yaml_string | parsed_value
#     ""          | false
#     "false"     | false
#     "true"      | true
#   end

#   test "#parse returns Config with name and Command objects from dev.yml" do
#     Given "A dev.yml file with name and commands"
#     tmp_file = Tempfile.new("dev.yml")
#     tmp_file.write <<~YAML
#       name: dev
#       commands:
#         up:
#           desc: Up command!
#           run: ./bin/setup.rb
#         test:
#           run: rspec
#     YAML
#     tmp_file.flush

#     When "the config is parsed"
#     parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
#     config = parser.parse(T.must(tmp_file.path))

#     Then "we get the expected result"
#     assert_equal "dev", config.name
    
#     up_command = config.command("up")
#     assert_kind_of Dev::Command, up_command
#     assert_equal "./bin/setup.rb", up_command.run
#     assert_equal "Up command!", up_command.desc
#     assert_equal false, up_command.interactive
    
#     test_command = config.command("test")
#     assert_kind_of Dev::Command, test_command
#     assert_equal "rspec", test_command.run
#     assert_equal "(no description)", test_command.desc
#     assert_equal false, test_command.interactive
#     Cleanup "the tempfile is deleted"
#     tmp_file.delete
#   end

#   test "parse raises when file does not exist" do
#     Given "a ConfigParser"
#     parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
    
#     Expect "raises Errno::ENOENT when we try to parse a nonexistent dev.yml file"
#     assert_raises Errno::ENOENT do
#       parser.parse("/nonexistent/dev.yml")
#     end
#   end

#   test "parse raises when YAML is invalid" do
#     Given "an invalid dev.yml file"
#     tmp_file = Tempfile.new("dev.yml")
#     tmp_file.write("not: valid: yaml: [")
#     tmp_file.flush

#     Expect "raises Psych::SyntaxError when we try to parse it"
#     parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
#     assert_raises Psych::SyntaxError do
#       parser.parse(T.must(tmp_file.path))
#     end

#     Cleanup "the tempfile is deleted"
#     tmp_file.delete
#   end
# end

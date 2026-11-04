# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "dev/target_parser"
require "yaml"

transform!(RSpock::AST::Transformation)
class Dev::TargetParserTest < Minitest::Test
  test "parse_all turns the targets: mapping into Targets in declaration order, ids through the enums" do
    Given "cellbound-3d's declared targets, as dev.yml spells them"
    raw = YAML.safe_load(<<~YAML)
      cellbound-3d:
        desc: Client
        platforms: [win64, linux64]
        configs: [dev, release]
      cellbound-3d-server:
        platforms: [linux64]
        configs: [dev, release]
      opencell:
        desc: Simulation library
    YAML

    When
    targets = Dev::TargetParser.new.parse_all(raw)

    Then
    targets.keys == ["cellbound-3d", "cellbound-3d-server", "opencell"]
    targets["cellbound-3d"] == Dev::Lifecycle::Target.new(
      name: "cellbound-3d",
      desc: "Client",
      platforms: [Dev::Lifecycle::Platform::Win64, Dev::Lifecycle::Platform::Linux64],
      configs: [Dev::Lifecycle::Config::Development, Dev::Lifecycle::Config::Release],
    )
    targets["cellbound-3d-server"].desc == "(no description)"
    targets["cellbound-3d-server"].platforms == [Dev::Lifecycle::Platform::Linux64]
    targets["opencell"] == Dev::Lifecycle::Target.new(name: "opencell", desc: "Simulation library")
  end

  test "parse_all with no targets: key declares none" do
    Expect
    Dev::TargetParser.new.parse_all(nil) == {}
  end

  test "parse coerces a non-string desc the way CommandParser does: #{raw_desc.inspect}" do
    Expect
    Dev::TargetParser.new.parse("opencell", { "desc" => raw_desc }).desc == desc

    Where
    raw_desc | desc
    nil      | "(no description)"
    ""       | "(no description)"
    true     | "true"
    42       | "42"
  end

  test "targets: must be a mapping" do
    When
    Dev::TargetParser.new.parse_all(["cellbound-3d"])

    Then
    raises Dev::TargetParser::InvalidTargetsError
  end

  test "a target entry must be a mapping: #{entry.inspect}" do
    When
    Dev::TargetParser.new.parse_all({ "opencell" => entry })

    Then
    error = raises(Dev::TargetParser::InvalidTargetError)
    error.message.include?("target 'opencell'")

    Where
    entry
    nil
    "./bin/build"
    ["win64"]
  end

  test "an axis must be a list of ids: #{key}: #{raw.inspect}" do
    When
    Dev::TargetParser.new.parse("opencell", { key => raw })

    Then
    error = raises(Dev::TargetParser::InvalidAxisError)
    error.message.include?("target 'opencell': '#{key}' must be a list of ids")

    Where
    key         | raw
    "platforms" | "win64"
    "platforms" | [1]
    "configs"   | { "dev" => true }
  end

  test "an id outside dev's closed set is refused naming the target and listing the set: #{key}: #{id}" do
    When
    Dev::TargetParser.new.parse("opencell", { key => [id] })

    Then
    error = raises(Dev::TargetParser::InvalidAxisError)
    error.message.include?("target 'opencell': #{key}:")
    error.message.include?(set)

    Where
    key         | id            | set
    "platforms" | "Win64"       | "win64, linux64, macos"
    "platforms" | "windows-x64" | "win64, linux64, macos"
    "configs"   | "Shipping"    | "debug, dev, release"
  end

  test "the rules a target owns surface from its constructor: #{name} #{entry.inspect}" do
    When
    Dev::TargetParser.new.parse(name, entry)

    Then
    raises error_class

    Where
    name                 | entry                                    | error_class
    "cellbound-3d-win64" | {}                                       | Dev::Lifecycle::Target::ReservedTargetSuffixError
    "Cellbound"          | {}                                       | Dev::Lifecycle::Target::InvalidTargetNameError
    "opencell"           | { "configs" => ["release", "release"] }  | Dev::Lifecycle::Target::DuplicateAxisValueError
  end
end

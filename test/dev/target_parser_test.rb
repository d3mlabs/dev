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

  test "build: and package: are the script forms; packager: a built-in by name; neither packager key means archive" do
    Given "cellbound-3d's editor, client and snappy's steam targets, as dev.yml spells them"
    raw = YAML.safe_load(<<~YAML)
      cellbound-3d-editor:
        platforms: [linux64, macos]
        build: ./bin/build-editor
        packager: none
      cellbound-3d:
        platforms: [win64, linux64]
        configs: [dev, release]
        build: ./bin/build
      snappy-steam:
        platforms: [win64]
        build: ./bin/build.sh
        packager: as-is
      combatmode:
        build: ./bin/layout
        package: ./bin/zip-addon
      rspock: {}
    YAML

    When
    targets = Dev::TargetParser.new.parse_all(raw)

    Then
    targets["cellbound-3d-editor"].builder == Dev::Lifecycle::BuilderSpec::Script.new(command: "./bin/build-editor")
    targets["cellbound-3d-editor"].packager == Dev::Lifecycle::PackagerSpec::None.new
    !targets["cellbound-3d-editor"].packageable?
    targets["cellbound-3d"].builder == Dev::Lifecycle::BuilderSpec::Script.new(command: "./bin/build")
    targets["cellbound-3d"].packager == Dev::Lifecycle::PackagerSpec::Archive.new
    targets["snappy-steam"].packager == Dev::Lifecycle::PackagerSpec::AsIs.new
    targets["combatmode"].packager == Dev::Lifecycle::PackagerSpec::Script.new(command: "./bin/zip-addon")
    targets["rspock"].builder.nil?
    targets["rspock"].packager == Dev::Lifecycle::PackagerSpec::Archive.new
  end

  test "packager: archive takes its form as options: #{options.inspect}" do
    Given
    raw = YAML.safe_load(options)

    Expect
    Dev::TargetParser.new.parse("ue-toolchain", { "packager" => raw }).packager ==
      Dev::Lifecycle::PackagerSpec::Archive.new(form: form)

    Where
    options                                   | form
    "archive"                                 | Dev::Lifecycle::Archive::Form::Zip.new
    "{ archive: {} }"                         | Dev::Lifecycle::Archive::Form::Zip.new
    "{ archive: { format: zip } }"            | Dev::Lifecycle::Archive::Form::Zip.new
    "{ archive: { format: tar } }"            | Dev::Lifecycle::Archive::Form::Tar.new
    "{ archive: { split: 2GiB } }"            | Dev::Lifecycle::Archive::Form::Tar.new(split: Dev::Lifecycle::ByteSize.parse("2GiB"))
    "{ archive: { format: tar, split: 2GiB } }" | Dev::Lifecycle::Archive::Form::Tar.new(split: Dev::Lifecycle::ByteSize.parse("2GiB"))
  end

  test "a build: or package: line must be a command: #{key}: #{raw.inspect}" do
    When
    Dev::TargetParser.new.parse("opencell", { key => raw })

    Then
    error = raises(error_class)
    error.message.include?("target 'opencell': `#{key}:` must be a command line")

    Where
    key       | raw     | error_class
    "build"   | ""      | Dev::TargetParser::InvalidBuilderError
    "build"   | true    | Dev::TargetParser::InvalidBuilderError
    "build"   | ["sh"]  | Dev::TargetParser::InvalidBuilderError
    "package" | "   "   | Dev::TargetParser::InvalidPackagerError
    "package" | nil     | Dev::TargetParser::InvalidPackagerError
  end

  test "builder: is the integration form, refused until it lands, pointing at build:" do
    When
    Dev::TargetParser.new.parse("cellbound-3d", { "builder" => "unreal" })

    Then
    error = raises(Dev::TargetParser::InvalidBuilderError)
    error.message.include?("d3mlabs/dev#433")
    error.message.include?("`build:`")
  end

  test "both package: and packager: on one target is a conflict" do
    When
    Dev::TargetParser.new.parse("snappy-steam", { "package" => "./bin/package", "packager" => "as-is" })

    Then
    error = raises(Dev::TargetParser::ConflictingPackagerError)
    error.message.include?("target 'snappy-steam'")
  end

  test "a packager: that is not a built-in, or carries options it does not take, is refused: #{raw.inspect}" do
    When
    Dev::TargetParser.new.parse("opencell", { "packager" => YAML.safe_load(raw) })

    Then
    error = raises(Dev::TargetParser::InvalidPackagerError)
    error.message.include?("target 'opencell'")
    error.message.include?(message)

    Where
    raw                                        | message
    "rubygem"                                  | "unknown packager \"rubygem\" (built-ins: archive, as-is, none)"
    "[archive]"                                | "must be a built-in's name or a mapping"
    "{ archive: {}, as-is: {} }"               | "one built-in's name to its options"
    "{ archive: tar }"                         | "one built-in's name to its options"
    "{ as-is: { strip: true } }"               | "as-is takes no options, got strip"
    "{ none: { why: not } }"                   | "none takes no options, got why"
    "{ archive: { level: 9 } }"                | "archive takes format, split, not level"
    "{ archive: { format: 7z } }"              | "archive: unknown archive format \"7z\""
    "{ archive: { split: 2GB } }"              | "archive: \"2GB\" is not a size"
    "{ archive: { format: zip, split: 2GiB } }" | "archive: `split:` needs the tar format"
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

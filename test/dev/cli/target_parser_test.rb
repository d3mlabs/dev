# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "dev/cli/target_parser"
require "yaml"

transform!(RSpock::AST::Transformation)
class Dev::Cli::TargetParserTest < Minitest::Test
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
    targets = Dev::Cli::TargetParser.new.parse_all(raw)

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
    Dev::Cli::TargetParser.new.parse_all(nil) == {}
  end

  test "parse coerces a non-string desc the way CommandParser does: #{raw_desc.inspect}" do
    Expect
    Dev::Cli::TargetParser.new.parse("opencell", { "desc" => raw_desc }).desc == desc

    Where
    raw_desc | desc
    nil      | "(no description)"
    ""       | "(no description)"
    true     | "true"
    42       | "42"
  end

  test "targets: must be a mapping" do
    When
    Dev::Cli::TargetParser.new.parse_all(["cellbound-3d"])

    Then
    raises Dev::Cli::TargetParser::InvalidTargetsError
  end

  test "a target entry must be a mapping: #{entry.inspect}" do
    When
    Dev::Cli::TargetParser.new.parse_all({ "opencell" => entry })

    Then
    error = raises(Dev::Cli::TargetParser::InvalidTargetError)
    error.message.include?("target 'opencell'")

    Where
    entry
    nil
    "./bin/build"
    ["win64"]
  end

  test "an axis must be a list of ids: #{key}: #{raw.inspect}" do
    When
    Dev::Cli::TargetParser.new.parse("opencell", { key => raw })

    Then
    error = raises(Dev::Cli::TargetParser::InvalidAxisError)
    error.message.include?("target 'opencell': '#{key}' must be a list of ids")

    Where
    key         | raw
    "platforms" | "win64"
    "platforms" | [1]
    "configs"   | { "dev" => true }
  end

  test "an id outside dev's closed set is refused naming the target and listing the set: #{key}: #{id}" do
    When
    Dev::Cli::TargetParser.new.parse("opencell", { key => [id] })

    Then
    error = raises(Dev::Cli::TargetParser::InvalidAxisError)
    error.message.include?("target 'opencell': #{key}:")
    error.message.include?(set)

    Where
    key         | id            | set
    "platforms" | "Win64"       | "win64, linux64, macos"
    "platforms" | "windows-x64" | "win64, linux64, macos"
    "configs"   | "Shipping"    | "debug, dev, release"
  end

  test "builder: and packager: each take a script as a string or a built-in by name; no packager: means archive (dev#692)" do
    Given "cellbound-3d's editor, client and snappy's steam targets, as dev.yml spells them"
    raw = YAML.safe_load(<<~YAML)
      cellbound-3d-editor:
        platforms: [linux64, macos]
        builder: ./bin/build-editor
        packager: none
      cellbound-3d:
        platforms: [win64, linux64]
        configs: [dev, release]
        builder: ./bin/build
      snappy-steam:
        platforms: [win64]
        builder: ./bin/build.sh
        packager: as-is
      combatmode:
        builder: ./bin/layout
        packager: ./bin/zip-addon
      rspock: {}
    YAML

    When
    targets = Dev::Cli::TargetParser.new.parse_all(raw)

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

  test "a packager: string that is not a built-in's name is a script: #{raw.inspect}" do
    Expect
    Dev::Cli::TargetParser.new.parse("combatmode", { "packager" => raw }).packager ==
      Dev::Lifecycle::PackagerSpec::Script.new(command: raw)

    Where
    raw
    "./bin/zip-addon"
    "make package"
    "rubygem"
  end

  test "build: and package: are no longer target keys: the parser reads only builder: and packager: (the loader refuses the retired spellings)" do
    Given "a target spelling its ports the current way beside a stray retired key the loader would have refused"
    raw = YAML.safe_load(<<~YAML)
      snappy-steam:
        builder: ./bin/build.sh
        packager: as-is
    YAML

    When
    targets = Dev::Cli::TargetParser.new.parse_all(raw)

    Then
    targets["snappy-steam"].builder == Dev::Lifecycle::BuilderSpec::Script.new(command: "./bin/build.sh")
    targets["snappy-steam"].packager == Dev::Lifecycle::PackagerSpec::AsIs.new
    !Dev::Cli::TargetParser.const_defined?(:DEPRECATED_PORT_KEYS)
    !Dev::Cli::TargetParser.const_defined?(:ConflictingPortError)
  end

  test "packager: archive takes its form and vendoring as options: #{options.inspect}" do
    Given
    raw = YAML.safe_load(options)

    Expect
    Dev::Cli::TargetParser.new.parse("ue-toolchain", { "packager" => raw }).packager ==
      Dev::Lifecycle::PackagerSpec::Archive.new(form: form, vendor: vendor)

    Where
    options                                   | form                                                                                  | vendor
    "archive"                                 | Dev::Lifecycle::Archive::Form::Zip.new                                                | false
    "{ archive: {} }"                         | Dev::Lifecycle::Archive::Form::Zip.new                                                | false
    "{ archive: { format: zip } }"            | Dev::Lifecycle::Archive::Form::Zip.new                                                | false
    "{ archive: { format: tar } }"            | Dev::Lifecycle::Archive::Form::Tar.new                                                | false
    "{ archive: { split: 2GiB } }"            | Dev::Lifecycle::Archive::Form::Tar.new(split: Dev::Lifecycle::ByteSize.parse("2GiB")) | false
    "{ archive: { format: tar, split: 2GiB } }" | Dev::Lifecycle::Archive::Form::Tar.new(split: Dev::Lifecycle::ByteSize.parse("2GiB")) | false
    "{ archive: { vendor: true } }"           | Dev::Lifecycle::Archive::Form::Zip.new                                                | true
    "{ archive: { vendor: false } }"          | Dev::Lifecycle::Archive::Form::Zip.new                                                | false
    "{ archive: { format: tar, vendor: true } }" | Dev::Lifecycle::Archive::Form::Tar.new                                             | true
  end

  test "packager: archive takes files: as a list of gitignore-syntax patterns, in order, beside its other options (dev#675)" do
    Given "dev's own two targets, as dev.yml spells them, and a tar form carrying a selection"
    raw = YAML.safe_load(<<~YAML)
      dev-core:
        packager:
          archive:
            files:
              - bin
              - lib
              - "!lib/scratch"
              - VERSION
      dev:
        packager: { archive: { files: [deploy/d3mlabs/config.yml, deploy/d3mlabs/Brewfile] } }
      ai-flow:
        packager: { archive: { format: tar, files: [exe, lib], vendor: true } }
    YAML

    When
    targets = Dev::Cli::TargetParser.new.parse_all(raw)

    Then
    targets["dev-core"].packager ==
      Dev::Lifecycle::PackagerSpec::Archive.new(files: Dev::Lifecycle::FileSelection.parse(["bin", "lib", "!lib/scratch", "VERSION"]))
    targets["dev"].packager ==
      Dev::Lifecycle::PackagerSpec::Archive.new(files: Dev::Lifecycle::FileSelection.parse(["deploy/d3mlabs/config.yml", "deploy/d3mlabs/Brewfile"]))
    targets["ai-flow"].packager == Dev::Lifecycle::PackagerSpec::Archive.new(
      form: Dev::Lifecycle::Archive::Form::Tar.new, files: Dev::Lifecycle::FileSelection.parse(["exe", "lib"]), vendor: true,
    )
    targets["dev-core"].packager.to_s == "archive, files: bin lib !lib/scratch VERSION"
  end

  test "a port's script form must be a command line: #{key}: #{raw.inspect}" do
    When
    Dev::Cli::TargetParser.new.parse("opencell", { key => raw })

    Then
    error = raises(error_class)
    error.message.include?("target 'opencell': `#{key}:` must be a command line")

    Where
    key        | raw     | error_class
    "builder"  | ""      | Dev::Cli::TargetParser::InvalidBuilderError
    "builder"  | true    | Dev::Cli::TargetParser::InvalidBuilderError
    "builder"  | ["sh"]  | Dev::Cli::TargetParser::InvalidBuilderError
    "builder"  | nil     | Dev::Cli::TargetParser::InvalidBuilderError
    "packager" | "   "   | Dev::Cli::TargetParser::InvalidPackagerError
    "packager" | ""      | Dev::Cli::TargetParser::InvalidPackagerError
  end

  test "builder: as a mapping names a built-in, and dev has none yet" do
    When
    Dev::Cli::TargetParser.new.parse("cellbound-3d", { "builder" => { "unreal" => { "engine" => "5.6" } } })

    Then
    error = raises(Dev::Cli::TargetParser::InvalidBuilderError)
    error.message.include?("target 'cellbound-3d': `builder:` as a mapping names a built-in builder, and dev has none yet")
    error.message.include?("`builder: ./bin/build`")
  end

  test "a packager: that is neither a command line, a built-in nor a mapping is refused: #{raw.inspect}" do
    When
    Dev::Cli::TargetParser.new.parse("opencell", { "packager" => raw })

    Then
    error = raises(Dev::Cli::TargetParser::InvalidPackagerError)
    error.message.include?("target 'opencell': `packager:` is a script's command line, a built-in's name (archive, as-is, none)")
    error.message.include?("got #{raw.inspect}")

    Where
    raw
    nil
    ["archive"]
    42
    true
  end

  test "a packager: mapping naming no built-in, or carrying options it does not take, is refused: #{raw.inspect}" do
    When
    Dev::Cli::TargetParser.new.parse("opencell", { "packager" => YAML.safe_load(raw) })

    Then
    error = raises(Dev::Cli::TargetParser::InvalidPackagerError)
    error.message.include?("target 'opencell'")
    error.message.include?(message)

    Where
    raw                                        | message
    "{ rubygem: {} }"                          | "unknown packager \"rubygem\" (built-ins: archive, as-is, none)"
    "{ archive: {}, as-is: {} }"               | "one built-in's name to its options"
    "{ archive: tar }"                         | "one built-in's name to its options"
    "{ as-is: { strip: true } }"               | "as-is takes no options, got strip"
    "{ none: { why: not } }"                   | "none takes no options, got why"
    "{ archive: { level: 9 } }"                | "archive takes format, split, vendor, files, not level"
    "{ archive: { format: 7z } }"              | "archive: unknown archive format \"7z\""
    "{ archive: { split: 2GB } }"              | "archive: \"2GB\" is not a size"
    "{ archive: { format: zip, split: 2GiB } }" | "archive: `split:` needs the tar format"
    "{ archive: { vendor: yes please } }"      | "archive: `vendor:` is true or false, got \"yes please\""
    "{ archive: { vendor: 1 } }"               | "archive: `vendor:` is true or false, got 1"
    "{ archive: { files: bin } }"              | "archive: `files:` is a list of patterns (`[bin, lib, VERSION]`), got \"bin\""
    "{ archive: { files: [] } }"               | "archive: `files:` is a list of patterns (`[bin, lib, VERSION]`), got []"
    "{ archive: { files: [bin, 1] } }"         | "archive: `files:` is a list of patterns (`[bin, lib, VERSION]`), got [\"bin\", 1]"
    "{ archive: { files: [bin, \"!\"] } }"     | "archive: `files:` \"!\" is not a pattern: nothing to match"
  end

  test "the rules a target owns surface from its constructor: #{name} #{entry.inspect}" do
    When
    Dev::Cli::TargetParser.new.parse(name, entry)

    Then
    raises error_class

    Where
    name                 | entry                                                                              | error_class
    "cellbound-3d-win64" | {}                                                                                 | Dev::Lifecycle::Target::ReservedTargetSuffixError
    "Cellbound"          | {}                                                                                 | Dev::Lifecycle::Target::InvalidTargetNameError
    "opencell"           | { "configs" => ["release", "release"] }                                            | Dev::Lifecycle::Target::DuplicateAxisValueError
    "opencell"           | { "platforms" => ["win64"], "environment" => { "linux64" => "cellbound-3d-linux" } } | Dev::Lifecycle::Target::EnvironmentPlatformsError
  end

  test "environment: as one name is a single reference for every build — an image's, or host" do
    Given
    raw = YAML.safe_load(<<~YAML)
      cellbound-3d:
        platforms: [win64, linux64]
        configs: [dev, release]
        environment: cellbound-3d-linux
      opencell:
        environment: host
    YAML

    When
    targets = Dev::Cli::TargetParser.new.parse_all(raw)

    Then
    targets["cellbound-3d"].environment == Dev::Lifecycle::TargetEnvironment::Single.new(
      reference: Dev::EnvironmentRef::Image.new(name: "cellbound-3d-linux"),
    )
    targets["opencell"].environment == Dev::Lifecycle::TargetEnvironment::Single.new(reference: Dev::EnvironmentRef::Host.new)
  end

  test "environment: as a mapping is one reference per platform id, in declaration order" do
    Given "the editor, as cellbound-3d's dev.yml spells it"
    raw = YAML.safe_load(<<~YAML)
      platforms: [linux64, macos]
      environment: { linux64: cellbound-3d-linux, macos: host }
    YAML

    When
    target = Dev::Cli::TargetParser.new.parse("cellbound-3d-editor", raw)

    Then
    target.environment == Dev::Lifecycle::TargetEnvironment::PerPlatform.new(
      references: {
        Dev::Lifecycle::Platform::Linux64 => Dev::EnvironmentRef::Image.new(name: "cellbound-3d-linux"),
        Dev::Lifecycle::Platform::Macos => Dev::EnvironmentRef::Host.new,
      },
    )
  end

  test "environment: omitted leaves the target to the project's default" do
    Expect
    Dev::Cli::TargetParser.new.parse("opencell", {}).environment.nil?
  end

  test "environment: must be a name or a mapping of platform id to name: #{raw.inspect}" do
    When
    Dev::Cli::TargetParser.new.parse("opencell", { "platforms" => ["win64"], "environment" => raw })

    Then
    error = raises(Dev::Cli::TargetParser::InvalidEnvironmentError)
    error.message.include?("target 'opencell': 'environment'")
    error.message.include?(says)

    Where
    raw                        | says
    nil                        | "got nil"
    ""                         | 'got ""'
    42                         | "got 42"
    ["cellbound-3d-linux"]     | "got [\"cellbound-3d-linux\"]"
    { "win64" => nil }         | "got nil"
    { "win64" => "" }          | 'got ""'
    { "Win64" => "cb-linux" }  | "unknown platform \"Win64\" (expected win64, linux64, macos)"
  end
end

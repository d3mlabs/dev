# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/release_parser"
require "support/lifecycle_fixtures"
require "yaml"

transform!(RSpock::AST::Transformation)
class Dev::Cli::ReleaseParserTest < Minitest::Test
  include LifecycleFixtures

  def parse(yaml, targets: all_targets)
    Dev::Cli::ReleaseParser.new.parse(YAML.safe_load(yaml), targets)
  end

  test "targets: lists the builds a release contains, fully qualified, in declaration order" do
    When
    release = parse(<<~YAML)
      desc: Ship it
      targets: [cellbound-3d-release, cellbound-3d-server-linux64-release, rspock]
    YAML

    Then
    release.names == ["cellbound-3d-win64-release", "cellbound-3d-linux64-release", "cellbound-3d-server-linux64-release", "rspock"]
  end

  test "#{form} means every build of every packageable target, when each has one config" do
    When
    release = parse(yaml, targets: [steamworks_target, gem_target])

    Then
    release.names == ["cellbound-3d-steamworks-win64-release", "rspock"]

    Where
    form             | yaml
    "`release: {}`"  | "{}"
    "`release:`"     | "~"
    "a desc alone"   | "desc: Ship it"
  end

  test "the empty form over a target with several configs is the list's refusal, naming the fix" do
    When
    parse("{}", targets: [client_target])

    Then
    error = raises(Dev::Lifecycle::ReleaseBuilds::ConfigNotNamedError)
    error.message.include?("cellbound-3d-dev, cellbound-3d-release")
  end

  test "a shape that is not a release's is refused: #{fault}" do
    When
    parse(yaml)

    Then
    error = raises(error_class)
    error.message.include?("command 'release'")

    Where
    fault                       | yaml                                           | error_class
    "a run: body"               | "{ run: ./bin/release.rb, targets: [rspock] }" | Dev::Cli::ReleaseParser::ReleaseBodyError
    "children"                  | "{ commands: { gem: { run: x } } }"             | Dev::Cli::ReleaseParser::ReleaseChildrenError
    "an environment: key"       | "{ targets: [rspock], environment: host }"      | Dev::Cli::ReleaseParser::UnknownReleaseKeyError
    "a scalar"                  | "ship"                                          | Dev::Cli::ReleaseParser::InvalidReleaseError
    "a list"                    | "[rspock]"                                      | Dev::Cli::ReleaseParser::InvalidReleaseError
    "targets: not a list"       | "{ targets: rspock }"                           | Dev::Cli::ReleaseParser::ReleaseTargetsError
    "targets: empty"            | "{ targets: [] }"                               | Dev::Cli::ReleaseParser::ReleaseTargetsError
    "targets: with a non-name"  | "{ targets: [rspock, 3] }"                      | Dev::Cli::ReleaseParser::ReleaseTargetsError
  end

  test "the list's own rules surface from the parse: #{fault}" do
    When
    parse(yaml)

    Then
    raises(error_class)

    Where
    fault                           | yaml                                                      | error_class
    "a pattern naming two configs"  | "{ targets: [cellbound-3d-win64] }"                       | Dev::Lifecycle::ReleaseBuilds::ConfigNotNamedError
    "a build named twice"           | "{ targets: [rspock, rspock] }"                           | Dev::Lifecycle::ReleaseBuilds::DuplicateBuildError
    "a name no target spells"       | "{ targets: [snappy] }"                                   | Dev::Lifecycle::BuildPattern::UnknownTargetError
  end

  test "release_declared? is the shape of a declaration — a release mapping carrying targets: — #{what}" do
    Expect
    Dev::Cli::ReleaseParser.new.release_declared?(YAML.safe_load(yaml)) == declared

    Where
    what                                  | yaml                                         | declared
    "a release with targets:"             | "{ release: { targets: [rspock] } }"         | true
    "a release with a run: (a command)"   | "{ release: { run: ./bin/release.rb } }"     | false
    "a release with nothing under it"     | "{ release: ~ }"                             | false
    "no release at all"                   | "{ test: { run: t } }"                       | false
    "commands: not a mapping"             | "[release]"                                  | false
  end
end

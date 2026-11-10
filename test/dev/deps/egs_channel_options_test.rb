# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/egs_channel_options"
require "dev/lifecycle"
require "support/lifecycle_fixtures"

transform!(RSpock::AST::Transformation)
class Dev::Deps::EgsChannelOptionsTest < Minitest::Test
  include LifecycleFixtures

  TRACK = Dev::Lifecycle::Track
  ARTIFACT = Dev::Deps::EgsChannelOptions::Artifact
  BASE = { "organization" => "o-abc", "product" => "p-def" }.freeze
  WIN64 = { "id" => "a-win", "launch" => "Cellbound3D.exe" }.freeze

  def channel(options)
    Dev::Lifecycle::Channel.new(
      name: "egs", accepts: [Dev::Lifecycle::BuildPattern.parse("cellbound-3d", all_targets)],
      publisher: Dev::Lifecycle::PublisherSpec::Integration.new(name: "egs"), options:,
    )
  end

  def pattern(name)
    Dev::Lifecycle::BuildPattern.parse(name, all_targets)
  end

  test "parse reads the organization, the product, an artifact per pattern and the labels, defaulting testing to Testing and live to Live" do
    When
    options = Dev::Deps::EgsChannelOptions.parse(channel(BASE.merge("artifacts" => {
      "cellbound-3d-win64" => WIN64,
      "cellbound-3d-linux64" => { "id" => "a-linux", "launch" => "Cellbound3D.sh", "args" => "-nosplash" },
    })))

    Then
    options.organization == "o-abc"
    options.product == "p-def"
    options.artifacts == {
      pattern("cellbound-3d-win64") => ARTIFACT.new(id: "a-win", launch: "Cellbound3D.exe"),
      pattern("cellbound-3d-linux64") => ARTIFACT.new(id: "a-linux", launch: "Cellbound3D.sh", args: "-nosplash"),
    }
    options.labels == { TRACK::Testing => "Testing", TRACK::Live => "Live" }
    options.label_for(TRACK::Live) == "Live"
  end

  test "labels: overrides a track's label and leaves the other at its default" do
    When
    options = Dev::Deps::EgsChannelOptions.parse(channel(BASE.merge("artifacts" => { "cellbound-3d-win64" => WIN64 }, "labels" => { "testing" => "QA" })))

    Then
    options.labels == { TRACK::Testing => "QA", TRACK::Live => "Live" }
  end

  test "artifact_for is the one artifact whose pattern the build matches" do
    Given
    options = Dev::Deps::EgsChannelOptions.parse(channel(BASE.merge("artifacts" => { "cellbound-3d-win64" => WIN64 })))

    Expect
    options.artifact_for(build("cellbound-3d-win64-release")) == ARTIFACT.new(id: "a-win", launch: "Cellbound3D.exe")
  end

  test "artifact_for refuses a build no artifact takes" do
    Given
    options = Dev::Deps::EgsChannelOptions.parse(channel(BASE.merge("artifacts" => { "cellbound-3d-win64" => WIN64 })))

    When
    options.artifact_for(build("cellbound-3d-linux64-dev"))

    Then
    error = raises Dev::Deps::EgsChannelOptions::NoArtifactError
    error.message == "no artifact for cellbound-3d-linux64-dev: `egs: artifacts:` names cellbound-3d-win64 — add one for it"
  end

  test "artifact_for refuses a build two artifacts claim" do
    Given
    options = Dev::Deps::EgsChannelOptions.parse(channel(BASE.merge("artifacts" => { "cellbound-3d" => WIN64, "cellbound-3d-win64" => WIN64 })))

    When
    options.artifact_for(build("cellbound-3d-win64-release"))

    Then
    error = raises Dev::Deps::EgsChannelOptions::AmbiguousArtifactError
    error.message == "cellbound-3d-win64-release matches 2 artifact patterns (cellbound-3d, cellbound-3d-win64) — make `egs: artifacts:` " \
      "name one artifact per build"
  end

  test "parse refuses options missing a key the publisher needs" do
    When
    Dev::Deps::EgsChannelOptions.parse(channel(options))

    Then
    error = raises Dev::Deps::EgsChannelOptions::MissingOptionError
    error.message.start_with?("channel 'deploy egs': `egs: #{key}:` is missing")

    Where
    options                                                                        | key
    {}                                                                             | "artifacts"
    { "artifacts" => { "cellbound-3d-win64" => WIN64 }, "product" => "p" }         | "organization"
    { "artifacts" => { "cellbound-3d-win64" => WIN64 }, "organization" => "o" }    | "product"
  end

  test "parse refuses a value of the wrong shape, naming the key" do
    When
    Dev::Deps::EgsChannelOptions.parse(channel(BASE.merge(options)))

    Then
    error = raises Dev::Deps::EgsChannelOptions::InvalidOptionError
    error.message.start_with?("channel 'deploy egs': `egs: #{key}:` must")

    Where
    options                                                                                  | key
    { "artifacts" => [] }                                                                    | "artifacts"
    { "artifacts" => {} }                                                                    | "artifacts"
    { "artifacts" => { "cellbound-3d-win64" => "a-win" } }                                   | "artifacts: cellbound-3d-win64"
    { "artifacts" => { "cellbound-3d-win64" => { "launch" => "x.exe" } } }                   | "artifacts: cellbound-3d-win64: id"
    { "artifacts" => { "cellbound-3d-win64" => { "id" => "a" } } }                           | "artifacts: cellbound-3d-win64: launch"
    { "artifacts" => { "cellbound-3d-win64" => WIN64.merge("args" => ["-x"]) } }             | "artifacts: cellbound-3d-win64: args"
    { "artifacts" => { "cellbound-3d-win64" => WIN64 }, "organization" => 7 }                | "organization"
    { "artifacts" => { "cellbound-3d-win64" => WIN64 }, "product" => " " }                   | "product"
    { "artifacts" => { "cellbound-3d-win64" => WIN64 }, "labels" => "Live" }                 | "labels"
    { "artifacts" => { "cellbound-3d-win64" => WIN64 }, "labels" => { "live" => "" } }       | "labels"
  end

  test "an artifact pattern no accepted target spells, or a label keyed by no track, fails in the grammar's own words" do
    When
    Dev::Deps::EgsChannelOptions.parse(channel(BASE.merge(options)))

    Then
    raises error

    Where
    options                                                                             | error
    { "artifacts" => { "rspock" => WIN64 } }                                            | Dev::Lifecycle::BuildPattern::UnknownTargetError
    { "artifacts" => { "cellbound-3d-win64" => WIN64 }, "labels" => { "qa" => "QA" } }  | Dev::Lifecycle::UnknownTrackError
  end
end

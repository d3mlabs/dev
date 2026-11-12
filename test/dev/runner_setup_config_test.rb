# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/runner_setup_config"

transform!(RSpock::AST::Transformation)
class Dev::RunnerSetupConfigTest < Minitest::Test
  test "optional fields default to nil" do
    When "creating a config with only labels"
    config = Dev::RunnerSetupConfig.new(labels: "ue-engine")

    Then "and config.sh is not told to --replace: a held name is never taken over unless register says it is this family's own (dev#565)"
    config.labels == "ue-engine"
    config.dir.nil?
    config.name.nil?
    config.version.nil?
    config.replace == false
  end

  test "equality compares all fields" do
    Given "two identical configs"
    a = Dev::RunnerSetupConfig.new(labels: "ue-engine", dir: "~/r", name: "box", version: "2.335.1")
    b = Dev::RunnerSetupConfig.new(labels: "ue-engine", dir: "~/r", name: "box", version: "2.335.1")

    Expect
    a == b
    a.eql?(b)
    a.hash == b.hash
  end

  test "dir_suffix is the first label, sanitized for a dir name — #{labels.inspect} → #{suffix.inspect}" do
    Expect
    Dev::RunnerSetupConfig.new(labels: labels).dir_suffix == suffix

    Where
    labels                                  | suffix
    "ai-ask,ai-edit,ai-split"               | "ai-ask"
    "ai-orchestrator"                       | "ai-orchestrator"
    "ue 5.8/editor,macos"                   | "ue-5.8-editor"
    ""                                      | "default"
  end

  test "inequality when a field differs" do
    Given "two configs with different labels, and two differing only in whether config.sh may --replace"
    a = Dev::RunnerSetupConfig.new(labels: "ue-engine")
    b = Dev::RunnerSetupConfig.new(labels: "cellbound3d")
    replacing = Dev::RunnerSetupConfig.new(labels: "ue-engine", replace: true)

    Expect
    a != b
    a.hash != b.hash
    a != replacing
  end
end

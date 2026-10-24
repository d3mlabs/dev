# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::EvaluateTest < Minitest::Test
  test "evaluate returns the config a manifest file defines" do
    Given "a manifest on disk"
    dir = Pathname(Dir.mktmpdir("dev-evaluate-test-"))
    (dir / "dependencies.rb").write("Dev::Deps.define { brew \"jq\" }\n")

    When "evaluating it"
    config = Dev::Deps.evaluate(dir / "dependencies.rb")

    Then
    config.declarations.map(&:name) == ["jq"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "evaluate leaves last_config as it was — a library read never replaces the project's config" do
    Given "a project config already defined, and a manifest to read as a library"
    project_config = Dev::Deps.define { ruby "4.0.1" }
    dir = Pathname(Dir.mktmpdir("dev-evaluate-test-"))
    (dir / "dependencies.rb").write("Dev::Deps.define { brew \"jq\" }\n")

    When "evaluating the library"
    library_config = Dev::Deps.evaluate(dir / "dependencies.rb")

    Then "the library's config came back; the project's is still the last one defined"
    library_config.declarations.map(&:name) == ["jq"]
    Dev::Deps.last_config.equal?(project_config)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "evaluate raises ManifestNotFoundError for a path with no file" do
    Given "an empty directory"
    dir = Pathname(Dir.mktmpdir("dev-evaluate-test-"))

    When "evaluating a manifest that is not there"
    Dev::Deps.evaluate(dir / "dependencies.rb")

    Then
    raises Dev::Deps::ManifestNotFoundError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "evaluate raises UndefinedManifestError when the file never calls define, and does not leak a stale config" do
    Given "a stale config, and a manifest that defines nothing"
    Dev::Deps.define { ruby "9.9.9" }
    dir = Pathname(Dir.mktmpdir("dev-evaluate-test-"))
    (dir / "dependencies.rb").write("EVALUATE_TEST_CONSTANT = 1 unless defined?(EVALUATE_TEST_CONSTANT)\n")

    When "evaluating it"
    Dev::Deps.evaluate(dir / "dependencies.rb")

    Then
    raises Dev::Deps::UndefinedManifestError

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

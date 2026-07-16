# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/plan"
require "tmpdir"
require "fileutils"

transform!(RSpock::AST::Transformation)
class Dev::Plan::SettingsTest < Minitest::Test
  test "plans_repo reads from the config file" do
    Given "a config file declaring the org plans repo"
    dir = Dir.mktmpdir("ai-flow-settings-test-")
    path = File.join(dir, "config.yml")
    File.write(path, "plans_repo: d3mlabs/plans\n")
    settings = Dev::Plan::Settings.new(config_path: path)

    Expect
    settings.plans_repo == "d3mlabs/plans"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "DEV_PLANS_REPO overrides the config file" do
    Given "a config file and an ENV override"
    dir = Dir.mktmpdir("ai-flow-settings-test-")
    path = File.join(dir, "config.yml")
    File.write(path, "plans_repo: d3mlabs/plans\n")
    ENV["DEV_PLANS_REPO"] = "acme/plans"
    settings = Dev::Plan::Settings.new(config_path: path)

    Expect
    settings.plans_repo == "acme/plans"

    Cleanup
    ENV.delete("DEV_PLANS_REPO")
    FileUtils.rm_rf(dir)
  end

  test "an unset plans_repo raises with instructions" do
    Given "no config file"
    dir = Dir.mktmpdir("ai-flow-settings-test-")
    settings = Dev::Plan::Settings.new(config_path: File.join(dir, "config.yml"))

    When "reading the plans repo"
    settings.plans_repo

    Then
    raises Dev::Plan::Settings::MissingSettingError

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

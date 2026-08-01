# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/settings"
require "tmpdir"
require "fileutils"

transform!(RSpock::AST::Transformation)
class Dev::SettingsTest < Minitest::Test
  test "plans_repo reads from the config file" do
    Given "a config file declaring the org plans repo"
    dir = Dir.mktmpdir("dev-settings-test-")
    path = File.join(dir, "config.yml")
    File.write(path, "plans_repo: d3mlabs/plans\n")
    settings = Dev::Settings.new(config_path: path)

    Expect
    settings.plans_repo == "d3mlabs/plans"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "DEV_PLANS_REPO overrides the config file" do
    Given "a config file and an ENV override"
    dir = Dir.mktmpdir("dev-settings-test-")
    path = File.join(dir, "config.yml")
    File.write(path, "plans_repo: d3mlabs/plans\n")
    ENV["DEV_PLANS_REPO"] = "acme/plans"
    settings = Dev::Settings.new(config_path: path)

    Expect
    settings.plans_repo == "acme/plans"

    Cleanup
    ENV.delete("DEV_PLANS_REPO")
    FileUtils.rm_rf(dir)
  end

  test "an unset plans_repo raises with instructions" do
    Given "no config file"
    dir = Dir.mktmpdir("dev-settings-test-")
    settings = Dev::Settings.new(config_path: File.join(dir, "config.yml"))

    When "reading the plans repo"
    settings.plans_repo

    Then
    raises Dev::Settings::MissingSettingError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "knowledge_repo reads from the config file" do
    Given "a config file declaring the org knowledge repo"
    dir = Dir.mktmpdir("dev-settings-test-")
    path = File.join(dir, "config.yml")
    File.write(path, "knowledge_repo: d3mlabs/knowledge\n")
    saved_env = ENV.delete("DEV_KNOWLEDGE_REPO")
    settings = Dev::Settings.new(config_path: path)

    Expect
    settings.knowledge_repo == "d3mlabs/knowledge"

    Cleanup
    ENV["DEV_KNOWLEDGE_REPO"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end

  test "DEV_KNOWLEDGE_REPO overrides the config file" do
    Given "a config file and an ENV override"
    dir = Dir.mktmpdir("dev-settings-test-")
    path = File.join(dir, "config.yml")
    File.write(path, "knowledge_repo: d3mlabs/knowledge\n")
    saved_env = ENV["DEV_KNOWLEDGE_REPO"]
    ENV["DEV_KNOWLEDGE_REPO"] = "acme/knowledge"
    settings = Dev::Settings.new(config_path: path)

    Expect
    settings.knowledge_repo == "acme/knowledge"

    Cleanup
    saved_env ? ENV["DEV_KNOWLEDGE_REPO"] = saved_env : ENV.delete("DEV_KNOWLEDGE_REPO")
    FileUtils.rm_rf(dir)
  end

  test "an unset knowledge_repo is nil — no org sync is a supported state" do
    Given "no config file"
    dir = Dir.mktmpdir("dev-settings-test-")
    saved_env = ENV.delete("DEV_KNOWLEDGE_REPO")
    settings = Dev::Settings.new(config_path: File.join(dir, "config.yml"))

    Expect
    settings.knowledge_repo.nil?

    Cleanup
    ENV["DEV_KNOWLEDGE_REPO"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end
end

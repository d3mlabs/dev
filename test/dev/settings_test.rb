# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/settings"
require "tmpdir"
require "fileutils"

transform!(RSpock::AST::Transformation)
class Dev::SettingsTest < Minitest::Test
  # Build Settings with hermetic layer paths: both files live in the temp
  # dir, so the machine's real user/system config never leaks into a test.
  def build_settings(dir)
    Dev::Settings.new(
      config_path: File.join(dir, "user", "config.yml"),
      system_config_path: File.join(dir, "system", "config.yml"),
    )
  end

  def write_user(dir, content)
    path = File.join(dir, "user", "config.yml")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def write_system(dir, content)
    path = File.join(dir, "system", "config.yml")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  test "plans_repo reads from the user config file" do
    Given "a user config file declaring the org plans repo"
    dir = Dir.mktmpdir("dev-settings-test-")
    write_user(dir, "plans_repo: d3mlabs/plans\n")
    settings = build_settings(dir)

    Expect
    settings.plans_repo == "d3mlabs/plans"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "DEV_PLANS_REPO overrides the config file" do
    Given "a config file and an ENV override"
    dir = Dir.mktmpdir("dev-settings-test-")
    write_user(dir, "plans_repo: d3mlabs/plans\n")
    ENV["DEV_PLANS_REPO"] = "acme/plans"
    settings = build_settings(dir)

    Expect
    settings.plans_repo == "acme/plans"

    Cleanup
    ENV.delete("DEV_PLANS_REPO")
    FileUtils.rm_rf(dir)
  end

  test "an unset plans_repo raises with instructions" do
    Given "no config file in either layer"
    dir = Dir.mktmpdir("dev-settings-test-")
    settings = build_settings(dir)

    When "reading the plans repo"
    settings.plans_repo

    Then
    raises Dev::Settings::MissingSettingError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a key falls through to the system config file" do
    Given "only the system layer (an org deployment's file) declares the key"
    dir = Dir.mktmpdir("dev-settings-test-")
    write_system(dir, "plans_repo: d3mlabs/plans\n")
    settings = build_settings(dir)

    Expect
    settings.plans_repo == "d3mlabs/plans"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the user file wins over the system file per key, gitconfig-style" do
    Given "both layers set plans_repo, and only the system layer sets knowledge_repo"
    dir = Dir.mktmpdir("dev-settings-test-")
    write_system(dir, "plans_repo: d3mlabs/plans\nknowledge_repo: d3mlabs/knowledge\n")
    write_user(dir, "plans_repo: personal/plans\n")
    saved_env = ENV.delete("DEV_KNOWLEDGE_REPO")
    settings = build_settings(dir)

    Expect "the user's plans_repo wins while the system knowledge_repo still applies"
    settings.plans_repo == "personal/plans"
    settings.knowledge_repo == "d3mlabs/knowledge"

    Cleanup
    ENV["DEV_KNOWLEDGE_REPO"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end

  test "knowledge_repo reads from the config file" do
    Given "a config file declaring the org knowledge repo"
    dir = Dir.mktmpdir("dev-settings-test-")
    write_user(dir, "knowledge_repo: d3mlabs/knowledge\n")
    saved_env = ENV.delete("DEV_KNOWLEDGE_REPO")
    settings = build_settings(dir)

    Expect
    settings.knowledge_repo == "d3mlabs/knowledge"

    Cleanup
    ENV["DEV_KNOWLEDGE_REPO"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end

  test "DEV_KNOWLEDGE_REPO overrides the config file" do
    Given "a config file and an ENV override"
    dir = Dir.mktmpdir("dev-settings-test-")
    write_user(dir, "knowledge_repo: d3mlabs/knowledge\n")
    saved_env = ENV["DEV_KNOWLEDGE_REPO"]
    ENV["DEV_KNOWLEDGE_REPO"] = "acme/knowledge"
    settings = build_settings(dir)

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
    settings = build_settings(dir)

    Expect
    settings.knowledge_repo.nil?

    Cleanup
    ENV["DEV_KNOWLEDGE_REPO"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end

  test "deployment_formula reads from the system config file (the deployment names itself)" do
    Given "a system config declaring the deployment's own formula"
    dir = Dir.mktmpdir("dev-settings-test-")
    write_system(dir, "deployment_formula: d3mlabs/d3mlabs/dev\n")
    saved_env = ENV.delete("DEV_DEPLOYMENT_FORMULA")
    settings = build_settings(dir)

    Expect
    settings.deployment_formula == "d3mlabs/d3mlabs/dev"

    Cleanup
    ENV["DEV_DEPLOYMENT_FORMULA"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end

  test "DEV_DEPLOYMENT_FORMULA overrides the config files" do
    Given "a system config and an ENV override"
    dir = Dir.mktmpdir("dev-settings-test-")
    write_system(dir, "deployment_formula: d3mlabs/d3mlabs/dev\n")
    saved_env = ENV["DEV_DEPLOYMENT_FORMULA"]
    ENV["DEV_DEPLOYMENT_FORMULA"] = "acme/tap/dev"
    settings = build_settings(dir)

    Expect
    settings.deployment_formula == "acme/tap/dev"

    Cleanup
    saved_env ? ENV["DEV_DEPLOYMENT_FORMULA"] = saved_env : ENV.delete("DEV_DEPLOYMENT_FORMULA")
    FileUtils.rm_rf(dir)
  end

  test "an unset deployment_formula is nil — no deployment to self-update is a supported state" do
    Given "no config file"
    dir = Dir.mktmpdir("dev-settings-test-")
    saved_env = ENV.delete("DEV_DEPLOYMENT_FORMULA")
    settings = build_settings(dir)

    Expect
    settings.deployment_formula.nil?

    Cleanup
    ENV["DEV_DEPLOYMENT_FORMULA"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end

  test "system_config_path is exposed for the host converge to find the deployment payload" do
    Given "hermetic settings"
    dir = Dir.mktmpdir("dev-settings-test-")
    settings = build_settings(dir)

    Expect
    settings.system_config_path == File.join(dir, "system", "config.yml")

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

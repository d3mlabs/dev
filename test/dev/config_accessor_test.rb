# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/config_accessor"
require "fileutils"
require "stringio"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::ConfigAccessorTest < Minitest::Test
  # An accessor over hermetic settings: both file layers live in the temp
  # dir, so the machine's real config never leaks into a test.
  def build_accessor(dir)
    settings = Dev::Settings.new(
      config_path: File.join(dir, "user", "config.yml"),
      system_config_path: File.join(dir, "system", "config.yml"),
    )
    Dev::ConfigAccessor.new(settings: settings)
  end

  def write_layer(dir, layer, content)
    path = File.join(dir, layer, "config.yml")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  test "list shows every known key with its resolved value and source layer" do
    Given "a key in each file layer, one ENV override, and one unset key"
    dir = Dir.mktmpdir("dev-config-acc-test-")
    write_layer(dir, "user", "knowledge_repo: acme/knowledge\n")
    write_layer(dir, "system", "plans_repo: acme/plans\n")
    saved_env = ENV["DEV_DEPLOYMENT_FORMULA"]
    ENV["DEV_DEPLOYMENT_FORMULA"] = "acme/tap/dev"
    accessor = build_accessor(dir)
    out = StringIO.new

    When "listing"
    accessor.run(["list"], out: out)

    Then "each key names its value and origin, gitconfig --show-origin style"
    out.string.include?("plans_repo") && out.string.include?("acme/plans  (system)")
    out.string.include?("acme/knowledge  (user)")
    out.string.include?("acme/tap/dev  (env)")

    Cleanup
    saved_env ? ENV["DEV_DEPLOYMENT_FORMULA"] = saved_env : ENV.delete("DEV_DEPLOYMENT_FORMULA")
    FileUtils.rm_rf(dir)
  end

  test "list marks a key unset when no layer defines it" do
    Given "empty layers"
    dir = Dir.mktmpdir("dev-config-acc-test-")
    saved_env = ENV.delete("DEV_DEPLOYMENT_FORMULA")
    accessor = build_accessor(dir)
    out = StringIO.new

    When "listing"
    accessor.run(["list"], out: out)

    Then "the deployment key reads unset"
    out.string.match?(/deployment_formula\s+\(unset\)/)

    Cleanup
    ENV["DEV_DEPLOYMENT_FORMULA"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end

  test "get prints the resolved value" do
    Given "a system-layer value"
    dir = Dir.mktmpdir("dev-config-acc-test-")
    write_layer(dir, "system", "plans_repo: acme/plans\n")
    accessor = build_accessor(dir)
    out = StringIO.new

    When "getting the key"
    accessor.run(["get", "plans_repo"], out: out)

    Then "the bare value prints (script-consumable)"
    out.string == "acme/plans\n"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "get on an unset key raises, mapping to a non-zero exit at the CLI boundary" do
    Given "empty layers"
    dir = Dir.mktmpdir("dev-config-acc-test-")
    saved_env = ENV.delete("DEV_KNOWLEDGE_REPO")
    accessor = build_accessor(dir)

    When "getting an unset key"
    accessor.run(["get", "knowledge_repo"], out: StringIO.new)

    Then
    raises Dev::ConfigAccessor::UnsetKeyError

    Cleanup
    ENV["DEV_KNOWLEDGE_REPO"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end

  test "set writes the user file (creating it) and get round-trips the value" do
    Given "no config files at all"
    dir = Dir.mktmpdir("dev-config-acc-test-")
    accessor = build_accessor(dir)
    out = StringIO.new

    When "setting then getting the key"
    accessor.run(["set", "deployment_formula", "acme/tap/dev"], out: out)
    accessor.run(["get", "deployment_formula"], out: out)

    Then "the set confirmed its destination and the value round-tripped"
    out.string.include?("deployment_formula set in #{File.join(dir, "user", "config.yml")}")
    out.string.end_with?("acme/tap/dev\n")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "set preserves the user file's other keys" do
    Given "a user file with an existing key"
    dir = Dir.mktmpdir("dev-config-acc-test-")
    write_layer(dir, "user", "plans_repo: acme/plans\n")
    accessor = build_accessor(dir)

    When "setting a different key"
    accessor.run(["set", "knowledge_repo", "acme/knowledge"], out: StringIO.new)

    Then "both keys live in the file as plain string-keyed YAML"
    reloaded = YAML.safe_load(File.read(File.join(dir, "user", "config.yml")))
    reloaded == { "plans_repo" => "acme/plans", "knowledge_repo" => "acme/knowledge" }

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "an unknown key errors with the known-keys list" do
    Given "an accessor"
    dir = Dir.mktmpdir("dev-config-acc-test-")
    accessor = build_accessor(dir)

    When "setting a key outside the registry"
    error = nil
    begin
      accessor.run(["set", "favorite_color", "teal"], out: StringIO.new)
    rescue Dev::ConfigAccessor::UnknownKeyError => e
      error = e
    end

    Then "the error names the key and lists the valid ones"
    error.message.include?("favorite_color")
    error.message.include?("plans_repo")
    error.message.include?("deployment_formula")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "unrecognized invocations raise the usage error" do
    Given "an accessor"
    dir = Dir.mktmpdir("dev-config-acc-test-")
    accessor = build_accessor(dir)

    When "running #{args.inspect}"
    accessor.run(args, out: StringIO.new)

    Then
    raises Dev::ConfigAccessor::UsageError

    Cleanup
    FileUtils.rm_rf(dir)

    Where
    args                          | _
    []                            | 0
    ["frobnicate"]                | 0
    ["get"]                       | 0
    ["set", "plans_repo"]         | 0
    ["get", "plans_repo", "junk"] | 0
  end
end

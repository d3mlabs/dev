# typed: false
# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"

# Integration tests spawning the real bin/dev shim: the harness-env defense
# happens in the sh layer before Ruby boots (a leaked RUBYOPT is processed
# by the interpreter ahead of the script's first line), so only a real
# spawn can exercise it.
transform!(RSpock::AST::Transformation)
class Dev::BinDevTest < Minitest::Test
  BIN_DEV = File.expand_path("../../bin/dev", __dir__)

  # The env a `bundle exec` harness leaks into its children (ai-flow#44):
  # RUBYOPT force-activates the caller's bundle at interpreter startup and
  # BUNDLE_GEMFILE points it at a Gemfile dev has never heard of.
  HOSTILE_BUNDLER_ENV = {
    "RUBYOPT" => "-rbundler/setup",
    "RUBYLIB" => "/harness/.ai-flow/lib",
    "BUNDLE_GEMFILE" => "/nonexistent/harness/Gemfile",
    "BUNDLE_PATH" => "/nonexistent/harness/vendor",
    "BUNDLE_APP_CONFIG" => "/nonexistent/harness/.bundle",
    "BUNDLE_BIN_PATH" => "/nonexistent/harness/bin/bundle",
    "BUNDLER_VERSION" => "9.9.9",
  }.freeze

  test "dev boots under a foreign bundler activation instead of loading the caller's bundle" do
    Given "a directory with no dev.yml and a hostile bundle-exec environment"
    dir = Dir.mktmpdir("dev-bin-test-")

    When "running bin/dev there"
    _out, err, status = Open3.capture3(HOSTILE_BUNDLER_ENV, "sh", BIN_DEV, chdir: dir)

    Then "dev's own Ruby program ran — it reached its normal no-dev.yml refusal, not a bundler crash"
    !status.success?
    err.include?("no dev.yml found")
    !err.include?("bundler")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "dev's children never see the foreign bundler activation" do
    Given "a project whose dev.yml command prints the bundler keys, and a hostile environment"
    dir = Dir.mktmpdir("dev-bin-test-")
    probe = "ruby -e 'puts [ENV[%q(RUBYOPT)], ENV[%q(BUNDLE_GEMFILE)]].inspect'"
    File.write(File.join(dir, "dev.yml"), "name: probe-project\ncommands:\n  probe:\n    run: #{probe.inspect}\n")

    When "running the probe through dev"
    out, _err, status = Open3.capture3(HOSTILE_BUNDLER_ENV, "sh", BIN_DEV, "probe", chdir: dir)

    Then "the child sees neither key"
    status.success?
    out.include?("[nil, nil]")

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

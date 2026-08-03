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

  # Pins the exact unset set: dropping a key from the shim's scrub would
  # silently re-open the leak for that key. The stub ruby stands in for the
  # real one so the assertion sees the env exactly as the shim hands it
  # over, without dev's own Ruby machinery (or provisioning) in the way.
  test "the shim strips every bundler-activation key before ruby ever runs" do
    Given "a stub ruby printing the env it receives, and every scrub key planted hostile"
    dir = Dir.mktmpdir("dev-bin-test-")
    stub_bin = File.join(dir, "bin")
    FileUtils.mkdir_p(stub_bin)
    File.write(File.join(stub_bin, "ruby"), <<~SH)
      #!/bin/sh
      # The shim's version probe (`ruby -e ...`) passes; the real exec
      # (`ruby -x bin/dev`) prints the env instead of running dev.
      case "$1" in
        -e) exit 0 ;;
        *) env ;;
      esac
    SH
    FileUtils.chmod(0o755, File.join(stub_bin, "ruby"))
    scrub_keys = %w[
      RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_APP_CONFIG
      BUNDLE_BIN BUNDLE_BIN_PATH BUNDLER_VERSION BUNDLER_SETUP
    ]
    hostile = scrub_keys.to_h { |key| [key, "/hostile/#{key}"] }
    env = hostile.merge("PATH" => "#{stub_bin}:#{ENV.fetch("PATH")}")

    When "running the shim"
    out, _err, status = Open3.capture3(env, "sh", BIN_DEV, chdir: dir)

    Then "no hostile key survives into the ruby process"
    status.success?
    # Whole-name matches: the suite's own env carries inert BUNDLER_ORIG_*
    # records whose names contain scrub keys as substrings.
    (out.lines.map { |line| line.split("=", 2).first } & scrub_keys).empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/global_dispatch"
require "open3"
require "tmpdir"

# bin/dev opens with an `unset` of the caller's bundler-activation env
# (dev#94): a harness running under `bundle exec` leaks RUBYOPT/BUNDLE_*
# into every child, and the Ruby interpreter acts on RUBYOPT before the
# script's first line — so the defense lives in the sh layer, and only
# spawning the real shim can exercise it. Scrub tests, one property each:
#
# 1. dev still boots when the caller's env is hostile (the bug's symptom).
# 2. The shim hands Ruby an env with every scrub key removed (the fix,
#    key by key).
# 3. The scrub list keeps up with bundler: whatever the locked bundler
#    exports must be on it (the drift over time).
#
# The shim is also the one place the full argv routing (global dispatch,
# then Runner) is wired together, so its end-to-end routing behavior —
# help outside a project — is exercised here too.
transform!(RSpock::AST::Transformation)
class Dev::BinDevTest < Minitest::Test
  DEV_ROOT = File.expand_path("../..", __dir__)
  BIN_DEV = File.join(DEV_ROOT, "bin", "dev")

  # The scrub list, parsed from the shim's `unset` line (joining its
  # backslash continuations). The sh script is the single source of truth
  # — the scrub must run before any Ruby exists, so the list cannot live
  # in a Ruby constant; tests alias it by parsing rather than keeping a
  # copy that could drift.
  SHIM_UNSET_KEYS = File.read(BIN_DEV)[/^unset ((?:\\\n|[^\n])*)/, 1].gsub("\\\n", " ").split.freeze

  test "a hostile bundler env cannot stop dev from booting" do
    Given "a directory with no dev.yml, and the env a bundle-exec harness leaks (ai-flow#44)"
    dir = Dir.mktmpdir("dev-bin-test-")
    hostile = {
      "RUBYOPT" => "-rbundler/setup",
      "BUNDLE_GEMFILE" => "/nonexistent/harness/Gemfile",
    }

    # A project command with no global/no-project fallback: `up` outside a
    # project now converges the host baseline (a real host mutation), so it
    # can never be spawned from tests.
    When "running a project command (bare dev renders the global usage instead) there"
    _out, err, status = Open3.capture3(hostile, "sh", BIN_DEV, "test", chdir: dir)

    Then "dev reached its own no-dev.yml refusal — not a crash inside the caller's bundler"
    !status.success?
    err.include?("no dev.yml found")
    !err.include?("bundler")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "bare dev and dev --help outside a project print the global usage and exit 0" do
    Given "a directory with no dev.yml anywhere above it"
    dir = Dir.mktmpdir("dev-bin-test-")

    When "running bin/dev bare and with --help there"
    bare_out, _bare_err, bare_status = Open3.capture3("sh", BIN_DEV, chdir: dir)
    help_out, _help_err, help_status = Open3.capture3("sh", BIN_DEV, "--help", chdir: dir)

    Then "both succeed with the global command listing and the project hint"
    bare_status.success?
    help_status.success?
    bare_out.include?("Global commands (available anywhere):")
    bare_out.include?("Run dev inside a project that defines a dev.yml to see its commands.")
    Dev::GlobalDispatch::GLOBAL_COMMANDS.keys.all? { |name| bare_out.include?(name) }
    help_out == bare_out

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the shim removes every scrub key from the env it hands to ruby" do
    Given "every scrub key planted hostile, and a stub ruby that prints the env it receives"
    dir = Dir.mktmpdir("dev-bin-test-")
    hostile = SHIM_UNSET_KEYS.to_h { |key| [key, "/hostile/#{key}"] }
    env = hostile.merge("PATH" => "#{write_stub_ruby(dir)}:#{ENV.fetch("PATH")}")

    When "running the shim"
    out, _err, status = Open3.capture3(env, "sh", BIN_DEV, chdir: dir)

    Then "no scrub key survives into the ruby process"
    status.success?
    (env_names(out) & SHIM_UNSET_KEYS).empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  # The scrub list is a denylist of what `bundle exec` exports, and that
  # set grows across bundler versions — a new exported key would silently
  # re-open the leak. The live truth comes from the locked bundler itself:
  # a child launched under `bundle exec` reports every key its activation
  # exported (its ENV vs its Bundler.original_env). The launch is
  # constructed here — the parent's own activation keys are removed first
  # — because the suite's inherited env is whatever shell started it (an
  # agent harness, an IDE) and proves nothing about the locked bundler.
  # Subset direction only: keys the shim lists but this activation didn't
  # export (config-dependent ones like BUNDLE_PATH) are free no-ops, so
  # exact equality would only add flake.
  test "the scrub list covers every key the locked bundler exports" do
    Given "a child activated by the repo's bundle exec, from a base env with no prior activation"
    # nil values unset the keys; BUNDLE_GEMFILE especially must be absent,
    # or bundle exec's BUNDLER_ORIG_* record hides it from the diff.
    fresh_env = ENV.keys.grep(/\A(?:BUNDLE_|BUNDLER_|RUBYOPT\z|RUBYLIB\z)/).to_h { |key| [key, nil] }
    report_exported = 'puts((ENV.keys | Bundler.original_env.keys)' \
      ".select { |key| ENV[key] != Bundler.original_env[key] })"
    out, _err, status = Open3.capture3(fresh_env, "bundle", "exec", "ruby", "-e", report_exported, chdir: DEV_ROOT)
    # In scope: bundler/ruby activation keys. Out of scope: BUNDLER_ORIG_*
    # (bundler's inert restore records) and GEM_* (legitimate user config,
    # per dev#94).
    exported = out.split("\n").grep(/\A(?:BUNDLE_|BUNDLER_(?!ORIG_)|RUBYOPT\z|RUBYLIB\z)/)

    Expect "a fresh activation that exported the Gemfile pin, fully covered by the scrub list"
    status.success?
    exported.include?("BUNDLE_GEMFILE")
    (exported - SHIM_UNSET_KEYS).empty?
  end

  # A PATH-front stub standing in for ruby: the shim's version probe
  # (`ruby -e ...`) passes, and the real launch (`ruby -x bin/dev`) prints
  # the received env instead of running dev — so the assertion sees the
  # exact hand-off env without dev's Ruby machinery (or provisioning)
  # getting involved. Returns the bin dir to prepend to PATH.
  def write_stub_ruby(dir)
    stub_bin = File.join(dir, "bin")
    FileUtils.mkdir_p(stub_bin)
    File.write(File.join(stub_bin, "ruby"), <<~SH)
      #!/bin/sh
      case "$1" in
        -e) exit 0 ;;
        *) env ;;
      esac
    SH
    FileUtils.chmod(0o755, File.join(stub_bin, "ruby"))
    stub_bin
  end

  # Variable names from `env` output — whole names, because the suite's
  # own BUNDLER_ORIG_* records contain scrub keys as substrings.
  def env_names(env_output)
    env_output.lines.map { |line| line.split("=", 2).first }
  end
end

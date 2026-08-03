# typed: false
# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"

# bin/dev opens with an `unset` of the caller's bundler-activation env
# (dev#94): a harness running under `bundle exec` leaks RUBYOPT/BUNDLE_*
# into every child, and the Ruby interpreter acts on RUBYOPT before the
# script's first line — so the defense lives in the sh layer, and only
# spawning the real shim can exercise it. Three tests, one property each:
#
# 1. dev still boots when the caller's env is hostile (the bug's symptom).
# 2. The shim hands Ruby an env with every scrub key removed (the fix,
#    key by key).
# 3. The scrub list keeps up with bundler: whatever the locked bundler
#    exports must be on it (the drift over time).
transform!(RSpock::AST::Transformation)
class Dev::BinDevTest < Minitest::Test
  BIN_DEV = File.expand_path("../../bin/dev", __dir__)

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

    When "running bin/dev there"
    _out, err, status = Open3.capture3(hostile, "sh", BIN_DEV, chdir: dir)

    Then "dev reached its own no-dev.yml refusal — not a crash inside the caller's bundler"
    !status.success?
    err.include?("no dev.yml found")
    !err.include?("bundler")

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
  # re-open the leak. This suite itself runs under bundle exec, so the
  # live truth is at hand: every key where ENV differs from
  # Bundler.original_env was exported by the locked bundler. Subset
  # direction only: keys the shim lists but this launch didn't export
  # (config-dependent ones like BUNDLE_PATH) are free no-ops, so exact
  # equality would only add flake.
  test "the scrub list covers every key the running bundler exports" do
    Given "the env diff bundler's activation left on this test process"
    exported = (ENV.keys | Bundler.original_env.keys).select { |key| ENV[key] != Bundler.original_env[key] }
    # In scope: bundler/ruby activation keys. Out of scope: BUNDLER_ORIG_*
    # (bundler's inert restore records) and GEM_* (legitimate user config,
    # per dev#94).
    activation_key = /\A(?:BUNDLE_|BUNDLER_(?!ORIG_)|RUBYOPT\z|RUBYLIB\z)/
    hostile = exported.grep(activation_key)

    Expect "a bundler-activated suite (else this guard proves nothing), fully covered by the scrub list"
    hostile.include?("BUNDLE_GEMFILE")
    (hostile - SHIM_UNSET_KEYS).empty?
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

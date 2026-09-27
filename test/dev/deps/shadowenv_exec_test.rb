# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/shadowenv_exec"
require "open3"
require "tmpdir"
require "fileutils"

transform!(RSpock::AST::Transformation)
class Dev::Deps::ShadowenvExecTest < Minitest::Test
  # A stand-in `shadowenv` that behaves like the real one when the project
  # env is already active in the caller's shell: it applies nothing and
  # execs the command with the env it inherited. That is the case the scrub
  # exists for (dev#180) — under it, anything dev's own activation carries
  # would reach the child unchanged.
  def install_passthrough_shadowenv(dir)
    bin = Pathname(dir) / "bin"
    FileUtils.mkdir_p(bin)
    shim = bin / "shadowenv"
    shim.write(<<~SH)
      #!/bin/sh
      # argv: exec -- <command...>
      shift 2
      exec "$@"
    SH
    shim.chmod(0o755)
    bin
  end

  # Pins the exact scrub set rather than referencing the constant: dropping
  # any key from it would silently re-open a leak — dev's own GEM_HOME
  # (the Homebrew wrapper points it into the dev-core Cellar, dev#180) or a
  # sandboxed harness's bundler overrides (dev#89).
  test "runs the command through shadowenv exec in the project root with dev's Ruby env unset" do
    Given "a project root and a caller-supplied env"
    dir = Dir.mktmpdir("dev-shadowenv-exec-test-")
    shadowenv_exec = Dev::Deps::ShadowenvExec.new(project_root: dir)
    _pid, status = Process.wait2(Process.spawn("true"))

    When "capturing a command"
    result = shadowenv_exec.capture3("bundle", "install", env: { "BUNDLE_GEMFILE" => "#{dir}/Gemfile" })

    Then "the child is spawned under shadowenv with every scrub key nil'd and the caller's env kept"
    1 * Open3.capture3(
      {
        "BUNDLE_PATH" => nil,
        "BUNDLE_APP_CONFIG" => nil,
        "BUNDLE_BIN" => nil,
        "GEM_HOME" => nil,
        "GEM_PATH" => nil,
        "RUBYOPT" => nil,
        "RUBYLIB" => nil,
        "BUNDLE_GEMFILE" => "#{dir}/Gemfile",
      },
      "shadowenv", "exec", "--", "bundle", "install", chdir: dir
    ) >> ["out", "err", status]
    result == ["out", "err", status]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "dev's own GEM_HOME does not reach the child even when shadowenv applies nothing" do
    Given "dev running with its gem home exported, and a shadowenv that passes the env through untouched"
    dir = Dir.mktmpdir("dev-shadowenv-exec-test-")
    shim_bin = install_passthrough_shadowenv(dir)
    original_gem_home = ENV.fetch("GEM_HOME", nil)
    ENV["GEM_HOME"] = "#{dir}/dev-core/libexec"
    shadowenv_exec = Dev::Deps::ShadowenvExec.new(project_root: dir)

    When "capturing a command that reports the gem home it sees"
    out, _err, status = shadowenv_exec.capture3(
      "sh", "-c", 'printf "%s" "${GEM_HOME-unset}"',
      env: { "PATH" => "#{shim_bin}:#{ENV.fetch("PATH")}" },
    )

    Then "the child sees no GEM_HOME"
    status.success?
    out == "unset"

    Cleanup
    original_gem_home ? ENV["GEM_HOME"] = original_gem_home : ENV.delete("GEM_HOME")
    FileUtils.rm_rf(dir)
  end
end

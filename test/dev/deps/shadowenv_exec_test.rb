# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/shadowenv_exec"
require "open3"
require "tmpdir"
require "fileutils"

transform!(RSpock::AST::Transformation)
class Dev::Deps::ShadowenvExecTest < Minitest::Test
  # A stand-in `shadowenv` with the real one's activation rule: with
  # __shadowenv_data in the env the project is "already active" and nothing
  # is applied; without it the project's lisp runs — here, setting GEM_HOME
  # to the project's keg.
  def install_rule_shadowenv(dir)
    bin = Pathname(dir) / "bin"
    FileUtils.mkdir_p(bin)
    shim = bin / "shadowenv"
    shim.write(<<~SH)
      #!/bin/sh
      shift 2
      if [ -z "${__shadowenv_data-}" ]; then
        export GEM_HOME="#{dir}/keg/lib/ruby/gems/4.0.0"
      fi
      exec "$@"
    SH
    shim.chmod(0o755)
    bin
  end

  # Pinned to the caller's env exactly: this seam clears nothing. Env
  # hygiene is bin/dev's, once, at the entrypoint; the GEM_HOME +
  # __shadowenv_data pair that used to sit here compensated for the
  # dev-core wrapper's GEM_HOME export (dev#180/#274/#306/#333), and the
  # wrapper no longer exports it. A key reappearing here is a regression
  # to per-spawn hygiene, not a fix.
  test "runs the command through shadowenv exec in the project root with the caller's env and nothing cleared" do
    Given "a project root and a caller-supplied env"
    dir = Dir.mktmpdir("dev-shadowenv-exec-test-")
    shadowenv_exec = Dev::Deps::ShadowenvExec.new(project_root: dir)
    _pid, status = Process.wait2(Process.spawn("true"))

    When "capturing a command"
    result = shadowenv_exec.capture3("bundle", "install", env: { "BUNDLE_GEMFILE" => "#{dir}/Gemfile" })

    Then "the child is spawned under shadowenv with exactly the caller's env"
    1 * Open3.capture3(
      { "BUNDLE_GEMFILE" => "#{dir}/Gemfile" },
      "shadowenv", "exec", "--", "bundle", "install", chdir: dir
    ) >> ["out", "err", status]
    result == ["out", "err", status]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a caller's active project shell reaches the child untouched: marker and gem home both inherited" do
    Given "dev running inside an active project shell (the marker and the lisp's GEM_HOME exported)"
    dir = Dir.mktmpdir("dev-shadowenv-exec-test-")
    shim_bin = install_rule_shadowenv(dir)
    saved = ENV.slice("__shadowenv_data", "GEM_HOME")
    ENV["__shadowenv_data"] = "abc123:{}"
    ENV["GEM_HOME"] = "#{dir}/keg/lib/ruby/gems/4.0.0"
    shadowenv_exec = Dev::Deps::ShadowenvExec.new(project_root: dir)

    When "capturing a command that reports the marker and gem home it sees"
    out, _err, status = shadowenv_exec.capture3(
      "sh", "-c", 'printf "%s %s" "${__shadowenv_data-unset}" "${GEM_HOME-unset}"',
      env: { "PATH" => "#{shim_bin}:#{ENV.fetch("PATH")}" },
    )

    Then "shadowenv saw the activation as current and the child has the shell's keg gem home"
    status.success?
    out == "abc123:{} #{dir}/keg/lib/ruby/gems/4.0.0"

    Cleanup
    %w[__shadowenv_data GEM_HOME].each { |k| saved.key?(k) ? ENV[k] = saved[k] : ENV.delete(k) }
    FileUtils.rm_rf(dir)
  end

  test "a caller with no active project gets the project's activation applied by shadowenv itself" do
    Given "dev running from a shell with no marker and no gem home"
    dir = Dir.mktmpdir("dev-shadowenv-exec-test-")
    shim_bin = install_rule_shadowenv(dir)
    saved = ENV.slice("__shadowenv_data", "GEM_HOME")
    ENV.delete("__shadowenv_data")
    ENV.delete("GEM_HOME")
    shadowenv_exec = Dev::Deps::ShadowenvExec.new(project_root: dir)

    When "capturing a command that reports the gem home it sees"
    out, _err, status = shadowenv_exec.capture3(
      "sh", "-c", 'printf "%s" "${GEM_HOME-unset}"',
      env: { "PATH" => "#{shim_bin}:#{ENV.fetch("PATH")}" },
    )

    Then "the project's lisp ran: the child has the keg's gem home"
    status.success?
    out == "#{dir}/keg/lib/ruby/gems/4.0.0"

    Cleanup
    %w[__shadowenv_data GEM_HOME].each { |k| saved.key?(k) ? ENV[k] = saved[k] : ENV.delete(k) }
    FileUtils.rm_rf(dir)
  end
end

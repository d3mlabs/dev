# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/shadowenv_trust"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class ShadowenvTrustTest < Minitest::Test
  # A stand-in `shadowenv` that records how it was called (argv and cwd) and
  # exits as told — the real one's trust is a signature written with the
  # caller's key, which is exactly what a test must not depend on.
  def install_recording_shadowenv(dir, exit_code: 0, stderr: "")
    bin = Pathname(dir) / "bin"
    FileUtils.mkdir_p(bin)
    shim = bin / "shadowenv"
    shim.write(<<~SH)
      #!/bin/sh
      printf '%s\\n' "$PWD" "$*" > "#{dir}/calls"
      printf '%s' "#{stderr}" >&2
      exit #{exit_code}
    SH
    shim.chmod(0o755)
    bin
  end

  def with_path(bin)
    saved = ENV.fetch("PATH")
    ENV["PATH"] = "#{bin}:#{saved}"
    yield
  ensure
    ENV["PATH"] = saved
  end

  test "a project with a .shadowenv.d is trusted in place, whatever its files say" do
    Given "a project whose activation files are already current, and a recording shadowenv"
    dir = Dir.mktmpdir("shadowenv-trust-test-")
    project = Pathname(dir) / "project"
    FileUtils.mkdir_p(project / ".shadowenv.d")
    (project / ".shadowenv.d" / "510_ruby.lisp").write("(provide \"ruby\" \"4.0.9\")\n")
    bin = install_recording_shadowenv(dir)

    When "ensuring trust"
    trusted = with_path(bin) { Dev::ShadowenvTrust.new.ensure!(project_root: project) }

    Then "shadowenv trust ran in the project root, and the call is reported"
    trusted == true
    File.read("#{dir}/calls") == "#{project.realpath}\ntrust\n"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a project with no .shadowenv.d yet is left alone — the writers create and trust it" do
    Given "a bare project root"
    dir = Dir.mktmpdir("shadowenv-trust-test-")
    project = Pathname(dir) / "project"
    FileUtils.mkdir_p(project)
    bin = install_recording_shadowenv(dir)

    When "ensuring trust"
    trusted = with_path(bin) { Dev::ShadowenvTrust.new.ensure!(project_root: project) }

    Then "nothing ran"
    trusted == false
    !File.exist?("#{dir}/calls")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a refused trust is an error carrying shadowenv's own words, not a silent miss" do
    Given "a shadowenv that refuses"
    dir = Dir.mktmpdir("shadowenv-trust-test-")
    project = Pathname(dir) / "project"
    FileUtils.mkdir_p(project / ".shadowenv.d")
    bin = install_recording_shadowenv(dir, exit_code: 1, stderr: "Permission denied (os error 13)")

    When "ensuring trust"
    with_path(bin) { Dev::ShadowenvTrust.new.ensure!(project_root: project) }

    Then
    e = raises Dev::ShadowenvTrust::TrustFailedError
    e.message == "shadowenv trust failed in #{project}: Permission denied (os error 13)"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "no shadowenv on PATH is the same error class, naming the missing tool" do
    Given "a PATH with no shadowenv at all"
    dir = Dir.mktmpdir("shadowenv-trust-test-")
    project = Pathname(dir) / "project"
    FileUtils.mkdir_p(project / ".shadowenv.d")
    empty_bin = Pathname(dir) / "empty"
    FileUtils.mkdir_p(empty_bin)
    saved = ENV.fetch("PATH")
    ENV["PATH"] = empty_bin.to_s

    When "ensuring trust"
    Dev::ShadowenvTrust.new.ensure!(project_root: project)

    Then
    e = raises Dev::ShadowenvTrust::TrustFailedError
    e.message == "shadowenv trust failed in #{project}: shadowenv not found on PATH"

    Cleanup
    ENV["PATH"] = saved
    FileUtils.rm_rf(dir)
  end
end

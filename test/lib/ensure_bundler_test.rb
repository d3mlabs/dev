# typed: false
# frozen_string_literal: true

require "test_helper"
require "ensure_bundler"
require "fileutils"
require "tmpdir"

# Ensure BUNDLER_VERSION is defined (from dev repo's dependencies.rb)
load File.join(DEV_ROOT, "dependencies.rb") unless defined?(BUNDLER_VERSION)

transform!(RSpock::AST::Transformation)
class EnsureBundlerTest < Minitest::Test
  test "EnsureBundler.ensure! returns true when bundler satisfies requirement" do
    Given "a bundle command that reports a satisfying version"
    tmpdir = Dir.mktmpdir("bundler-test-")
    fake_bin = File.join(tmpdir, "bin")
    FileUtils.mkdir_p(fake_bin)
    File.write(File.join(fake_bin, "bundle"), "#!/bin/sh\necho 'Bundler version 2.5.0'")
    File.chmod(0o755, File.join(fake_bin, "bundle"))
    original_path = ENV["PATH"]
    ENV["PATH"] = "#{fake_bin}:#{original_path}"

    When "we call EnsureBundler.ensure!"
    result = EnsureBundler.ensure!(DEV_ROOT)

    Then "it returns true without attempting install"
    result == true

    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(tmpdir)
  end

  test "EnsureBundler.ensure! accepts Bundler 4's bare version output without installing" do
    Given "a bundle command that prints a bare satisfying version, as Bundler 4 does"
    tmpdir = Dir.mktmpdir("bundler-test-")
    fake_bin = File.join(tmpdir, "bin")
    FileUtils.mkdir_p(fake_bin)
    File.write(File.join(fake_bin, "bundle"), "#!/bin/sh\necho '4.0.3'")
    File.chmod(0o755, File.join(fake_bin, "bundle"))
    File.write(File.join(fake_bin, "gem"), "#!/bin/sh\necho 'gem install must not run' >&2\nexit 1")
    File.chmod(0o755, File.join(fake_bin, "gem"))
    original_path = ENV["PATH"]
    ENV["PATH"] = "#{fake_bin}:#{original_path}"

    When "we call EnsureBundler.ensure!"
    result = EnsureBundler.ensure!(DEV_ROOT)

    Then "it returns true without attempting install"
    result == true

    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(tmpdir)
  end

  test "EnsureBundler.ensure! ignores version-like fragments in a failing bundle's output" do
    Given "a bundle command that fails with a backtrace containing a path version"
    tmpdir = Dir.mktmpdir("bundler-test-")
    fake_bin = File.join(tmpdir, "bin")
    FileUtils.mkdir_p(fake_bin)
    File.write(File.join(fake_bin, "bundle"), "#!/bin/sh\necho '/lib/ruby/4.0.0/rubygems.rb:1: error' >&2\nexit 1")
    File.chmod(0o755, File.join(fake_bin, "bundle"))
    File.write(File.join(fake_bin, "gem"), "#!/bin/sh\nexit 0")
    File.chmod(0o755, File.join(fake_bin, "gem"))
    original_path = ENV["PATH"]
    ENV["PATH"] = "#{fake_bin}:#{original_path}"

    When "we call EnsureBundler.ensure!"
    result = EnsureBundler.ensure!(DEV_ROOT)

    Then "it falls through to install and returns true"
    _ * $stdout.puts
    result == true

    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(tmpdir)
  end

  test "EnsureBundler.ensure! installs when bundle is absent from PATH entirely" do
    Given "a PATH with gem but no bundle at all"
    tmpdir = Dir.mktmpdir("bundler-test-")
    fake_bin = File.join(tmpdir, "bin")
    FileUtils.mkdir_p(fake_bin)
    File.write(File.join(fake_bin, "gem"), "#!/bin/sh\nexit 0")
    File.chmod(0o755, File.join(fake_bin, "gem"))
    original_path = ENV["PATH"]
    ENV["PATH"] = fake_bin

    When "we call EnsureBundler.ensure!"
    result = EnsureBundler.ensure!(DEV_ROOT)

    Then "it returns true after installing"
    _ * $stdout.puts
    result == true

    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(tmpdir)
  end

  test "EnsureBundler.ensure! installs and returns true when version does not satisfy" do
    Given "bundle reports version 1.0.0 and gem install succeeds"
    tmpdir = Dir.mktmpdir("bundler-test-")
    fake_bin = File.join(tmpdir, "bin")
    FileUtils.mkdir_p(fake_bin)
    File.write(File.join(fake_bin, "bundle"), "#!/bin/sh\necho 'Bundler version 1.0.0'")
    File.chmod(0o755, File.join(fake_bin, "bundle"))
    File.write(File.join(fake_bin, "gem"), "#!/bin/sh\nexit 0")
    File.chmod(0o755, File.join(fake_bin, "gem"))
    original_path = ENV["PATH"]
    ENV["PATH"] = "#{fake_bin}:#{original_path}"

    When "we call EnsureBundler.ensure!"
    result = EnsureBundler.ensure!(DEV_ROOT)

    Then "it returns true after installing"
    _ * $stdout.puts
    result == true

    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(tmpdir)
  end

  test "EnsureBundler.ensure! raises when gem install fails" do
    Given "bundle reports old version and gem install fails"
    tmpdir = Dir.mktmpdir("bundler-test-")
    fake_bin = File.join(tmpdir, "bin")
    FileUtils.mkdir_p(fake_bin)
    File.write(File.join(fake_bin, "bundle"), "#!/bin/sh\necho 'Bundler version 1.0.0'")
    File.chmod(0o755, File.join(fake_bin, "bundle"))
    File.write(File.join(fake_bin, "gem"), "#!/bin/sh\necho 'install error' >&2\nexit 1")
    File.chmod(0o755, File.join(fake_bin, "gem"))
    original_path = ENV["PATH"]
    ENV["PATH"] = "#{fake_bin}:#{original_path}"

    When "we call EnsureBundler.ensure!"
    EnsureBundler.ensure!(DEV_ROOT)

    Then "it raises with a descriptive message"
    _ * $stdout.puts
    raises EnsureBundler::BundlerInstallError


    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(tmpdir)
  end

  test "EnsureBundler.ensure! installs when bundle command is not found" do
    Given "bundle command is not found and gem install succeeds"
    tmpdir = Dir.mktmpdir("bundler-test-")
    fake_bin = File.join(tmpdir, "bin")
    FileUtils.mkdir_p(fake_bin)
    File.write(File.join(fake_bin, "bundle"), "#!/bin/sh\necho 'command not found' >&2\nexit 127")
    File.chmod(0o755, File.join(fake_bin, "bundle"))
    File.write(File.join(fake_bin, "gem"), "#!/bin/sh\nexit 0")
    File.chmod(0o755, File.join(fake_bin, "gem"))
    original_path = ENV["PATH"]
    ENV["PATH"] = "#{fake_bin}:#{original_path}"


    When "we call EnsureBundler.ensure!"
    result = EnsureBundler.ensure!(DEV_ROOT)

    Then "it returns true"
    _ * $stdout.puts
    result == true

    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(tmpdir)
  end
end

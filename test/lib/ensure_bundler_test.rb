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
  test "ensure_bundler! returns true when bundler satisfies requirement" do
    Given "a bundle command that reports a satisfying version"
    tmpdir = Dir.mktmpdir("bundler-test-")
    fake_bin = File.join(tmpdir, "bin")
    FileUtils.mkdir_p(fake_bin)
    File.write(File.join(fake_bin, "bundle"), "#!/bin/sh\necho 'Bundler version 2.5.0'")
    File.chmod(0o755, File.join(fake_bin, "bundle"))
    original_path = ENV["PATH"]
    ENV["PATH"] = "#{fake_bin}:#{original_path}"

    When "we call ensure_bundler!"
    result = ensure_bundler!(DEV_ROOT)

    Then "it returns true without attempting install"
    result == true

    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(tmpdir)
  end

  test "ensure_bundler! installs and returns true when version does not satisfy" do
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

    When "we call ensure_bundler!"
    result = ensure_bundler!(DEV_ROOT)

    Then "it returns true after installing"
    result == true

    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(tmpdir)
  end

  test "ensure_bundler! returns false when gem install fails" do
    Given "bundle reports old version and gem install fails"
    tmpdir = Dir.mktmpdir("bundler-test-")
    fake_bin = File.join(tmpdir, "bin")
    FileUtils.mkdir_p(fake_bin)
    File.write(File.join(fake_bin, "bundle"), "#!/bin/sh\necho 'Bundler version 1.0.0'")
    File.chmod(0o755, File.join(fake_bin, "bundle"))
    File.write(File.join(fake_bin, "gem"), "#!/bin/sh\nexit 1")
    File.chmod(0o755, File.join(fake_bin, "gem"))
    original_path = ENV["PATH"]
    ENV["PATH"] = "#{fake_bin}:#{original_path}"

    When "we call ensure_bundler!"
    result = ensure_bundler!(DEV_ROOT)

    Then "it returns false"
    result == false

    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(tmpdir)
  end

  test "ensure_bundler! installs when bundle command is not found" do
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

    When "we call ensure_bundler!"
    result = ensure_bundler!(DEV_ROOT)

    Then "it attempts install and returns true"
    result == true

    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(tmpdir)
  end
end

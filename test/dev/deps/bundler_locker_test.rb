# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps"
require "dev/deps/bundler_locker"
require "open3"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::BundlerLockerTest < Minitest::Test
  def bundler_declarations(&block)
    Dev::Deps.define(&block).declarations.select { |d| d.integration == :bundler }
  end

  test "lock generates a Gemfile mapping dev groups to bundler groups" do
    Given "gem declarations in the default and test groups"
    dir = Dir.mktmpdir("dev-bundler-locker-test-")
    locker = Dev::Deps::BundlerLocker.new(project_root: dir, ruby_version_requirement: "~> 4.0")
    decls = bundler_declarations do
      gem "ffi", "~> 1.17"
      group :test do
        gem "minitest", "~> 5.0", require: false
      end
    end
    Open3.stubs(:capture3).returns(["", "", stub(success?: true)])

    When "locking the declaration set"
    locker.lock(decls)
    gemfile = (Pathname(dir) / "Gemfile").read

    Then "the Gemfile pins the source, ruby, default gem, and grouped gem with options"
    gemfile.include?(%(source "https://rubygems.org"))
    gemfile.include?(%(ruby "~> 4.0"))
    gemfile.include?(%(gem "ffi", "~> 1.17"))
    gemfile.include?("group :test do")
    gemfile.include?(%(  gem "minitest", "~> 5.0", require: false))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "lock is a no-op for an empty declaration set" do
    Given "no bundler declarations"
    dir = Dir.mktmpdir("dev-bundler-locker-test-")
    locker = Dev::Deps::BundlerLocker.new(project_root: dir)
    Open3.stubs(:capture3).raises("bundle lock should not run")

    When "locking"
    locker.lock([])

    Then "no Gemfile is written"
    !(Pathname(dir) / "Gemfile").exist?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "lock raises LockError when bundle lock fails" do
    Given "a bundle lock that will fail"
    dir = Dir.mktmpdir("dev-bundler-locker-test-")
    locker = Dev::Deps::BundlerLocker.new(project_root: dir)
    Open3.stubs(:capture3).returns(["", "could not resolve", stub(success?: false)])

    When "locking"
    locker.lock(bundler_declarations { gem "ffi" })

    Then
    raises Dev::Deps::BundlerLocker::LockError

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

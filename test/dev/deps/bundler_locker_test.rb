# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps"
require "dev/deps/bundler_locker"
require "dev/deps/shadowenv_exec"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::BundlerLockerTest < Minitest::Test
  def bundler_declarations(&block)
    Dev::Deps.define(&block).declarations.select { |d| d.integration == :bundler }
  end

  # A locker whose bundler boundary is the fake seam: the test owns what
  # `shadowenv exec -- bundle lock` answers, and can assert what it was sent.
  def build_locker(dir, shadowenv_exec, ruby_version_requirement: nil)
    Dev::Deps::BundlerLocker.new(
      project_root: dir,
      ruby_version_requirement: ruby_version_requirement,
      shadowenv_exec: shadowenv_exec,
    )
  end

  def succeeded = ["", "", stub(success?: true)]

  test "lock generates a Gemfile mapping dev groups to bundler groups" do
    Given "gem declarations in the default and test groups"
    dir = Dir.mktmpdir("dev-bundler-locker-test-")
    shadowenv_exec = Dev::Deps::ShadowenvExec.new(project_root: dir)
    shadowenv_exec.stubs(:capture3).returns(succeeded)
    locker = build_locker(dir, shadowenv_exec, ruby_version_requirement: "~> 4.0")
    decls = bundler_declarations do
      gem "ffi", "~> 1.17"
      group :test do
        gem "minitest", "~> 5.0", require: false
      end
    end

    When "locking the declaration set"
    locker.lock(decls)
    gemfile = (Pathname(dir) / "Gemfile").read

    Then "the Gemfile names the verb that regenerates it, and pins the source, ruby, default gem, and grouped gem with options"
    gemfile.include?("run `dev deps update`")
    gemfile.include?(%(source "https://rubygems.org"))
    gemfile.include?(%(ruby "~> 4.0"))
    gemfile.include?(%(gem "ffi", "~> 1.17"))
    gemfile.include?("group :test do")
    gemfile.include?(%(  gem "minitest", "~> 5.0", require: false))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "lock runs bundle lock through the project's shadowenv, against the generated Gemfile" do
    Given "a locker over the spawn seam"
    dir = Dir.mktmpdir("dev-bundler-locker-test-")
    shadowenv_exec = Dev::Deps::ShadowenvExec.new(project_root: dir)
    shadowenv_exec.expects(:capture3)
      .with("bundle", "lock", env: { "BUNDLE_GEMFILE" => (Pathname(dir) / "Gemfile").to_s })
      .returns(succeeded)
    locker = build_locker(dir, shadowenv_exec)

    When "locking"
    locker.lock(bundler_declarations { gem "ffi" })

    Then "bundle lock was sent to the seam, not spawned bare (asserted on the mock)"
    true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "lock is a no-op for an empty declaration set" do
    Given "no bundler declarations"
    dir = Dir.mktmpdir("dev-bundler-locker-test-")
    shadowenv_exec = Dev::Deps::ShadowenvExec.new(project_root: dir)
    shadowenv_exec.expects(:capture3).never
    locker = build_locker(dir, shadowenv_exec)

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
    shadowenv_exec = Dev::Deps::ShadowenvExec.new(project_root: dir)
    shadowenv_exec.stubs(:capture3).returns(["", "could not resolve", stub(success?: false)])
    locker = build_locker(dir, shadowenv_exec)

    When "locking"
    locker.lock(bundler_declarations { gem "ffi" })

    Then
    raises Dev::Deps::BundlerLocker::LockError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the seam defaults to the project's own shadowenv" do
    Given "a locker built without an explicit seam"
    dir = Dir.mktmpdir("dev-bundler-locker-test-")
    Dev::Deps::ShadowenvExec.expects(:new).with(project_root: Pathname(dir)).returns(stub)

    When "constructing"
    Dev::Deps::BundlerLocker.new(project_root: dir)

    Then "the default seam was built over the project root (asserted on the mock)"
    true

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

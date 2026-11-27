# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps"
require "dev/deps/bundler_locker"
require "dev/deps/shadowenv_exec"
require "dev/deps/unlock_set"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::BundlerLockerTest < Minitest::Test
  def bundler_declarations(&block)
    Dev::Deps.define(&block).declarations.select { |d| d.integration == :bundler }
  end

  # A locker whose bundler boundary is the fake seam: the test owns what
  # `shadowenv exec -- bundle lock` answers, and can assert what it was sent.
  def build_locker(dir, shadowenv_exec, ruby_version: nil)
    Dev::Deps::BundlerLocker.new(
      project_root: dir,
      ruby_version: ruby_version,
      shadowenv_exec: shadowenv_exec,
    )
  end

  def succeeded
    ["", "", exit_status(0)]
  end

  # The env every bundle lock runs under: the generated Gemfile.
  #
  # @param dir [String] the project root
  # @return [Hash{String => String}]
  def gemfile_env(dir)
    { "BUNDLE_GEMFILE" => (Pathname(dir) / "Gemfile").to_s }
  end

  test "lock generates a Gemfile mapping dev groups to bundler groups" do
    Given "gem declarations in the default and test groups"
    dir = Dir.mktmpdir("dev-bundler-locker-test-")
    shadowenv_exec = Dev::Deps::ShadowenvExec.new(project_root: dir)
    locker = build_locker(dir, shadowenv_exec, ruby_version: "4.0.9")
    decls = bundler_declarations do
      gem "ffi", "^1.17"
      group :test do
        gem "minitest", "~5.0", require: false
      end
    end

    When "locking the declaration set"
    locker.lock(decls)
    gemfile = (Pathname(dir) / "Gemfile").read

    Then "the Gemfile names the verb that regenerates it, and pins the source, the locked ruby, default gem, and grouped gem with options — ranges in bundler's grammar"
    _ * shadowenv_exec.capture3 >> succeeded
    gemfile.include?("run `dev deps update`")
    gemfile.include?(%(source "https://rubygems.org"))
    gemfile.include?(%(ruby "4.0.9"))
    gemfile.include?(%(gem "ffi", ">= 1.17.0", "< 2.0.0"))
    gemfile.include?("group :test do")
    gemfile.include?(%(  gem "minitest", ">= 5.0.0", "< 5.1.0", require: false))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "lock runs bundle lock through the project's shadowenv, against the generated Gemfile, floating every gem by default" do
    Given "a locker over the spawn seam"
    dir = Dir.mktmpdir("dev-bundler-locker-test-")
    shadowenv_exec = Dev::Deps::ShadowenvExec.new(project_root: dir)
    locker = build_locker(dir, shadowenv_exec)

    When "locking with no unlock given — the bare verb's shape"
    locker.lock(bundler_declarations { gem "ffi" })

    Then "bundle lock --update was sent to the seam, not spawned bare"
    1 * shadowenv_exec.capture3("bundle", "lock", "--update", env: gemfile_env(dir)) >> succeeded

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "lock floats the named gems through bundler's own unlock, ignoring names from other channels" do
    Given "a locker over the spawn seam, two gems declared, one of them and a brew formula named"
    dir = Dir.mktmpdir("dev-bundler-locker-test-")
    shadowenv_exec = Dev::Deps::ShadowenvExec.new(project_root: dir)
    locker = build_locker(dir, shadowenv_exec)
    decls = bundler_declarations do
      gem "ffi"
      gem "rake"
    end

    When "dev deps update rake cmake"
    locker.lock(decls, unlock: Dev::Deps::UnlockSet.new(names: ["rake", "cmake"]))

    Then "bundle lock --update rake was sent"
    1 * shadowenv_exec.capture3("bundle", "lock", "--update", "rake", env: gemfile_env(dir)) >> succeeded

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "lock keeps bundle lock conservative when no gem is named" do
    Given "a subset re-lock naming only a brew formula"
    dir = Dir.mktmpdir("dev-bundler-locker-test-")
    shadowenv_exec = Dev::Deps::ShadowenvExec.new(project_root: dir)
    locker = build_locker(dir, shadowenv_exec)

    When "dev deps update cmake"
    locker.lock(bundler_declarations { gem "ffi" }, unlock: Dev::Deps::UnlockSet.new(names: ["cmake"]))

    Then "plain bundle lock: Gemfile.lock keeps every gem that still satisfies the Gemfile"
    1 * shadowenv_exec.capture3("bundle", "lock", env: gemfile_env(dir)) >> succeeded

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "lock floats every gem for the full re-lock" do
    Given "a locker over the spawn seam"
    dir = Dir.mktmpdir("dev-bundler-locker-test-")
    shadowenv_exec = Dev::Deps::ShadowenvExec.new(project_root: dir)
    locker = build_locker(dir, shadowenv_exec)

    When "dev deps update, bare"
    locker.lock(bundler_declarations { gem "ffi" }, unlock: Dev::Deps::UnlockSet.all)

    Then "bundle lock --update was sent"
    1 * shadowenv_exec.capture3("bundle", "lock", "--update", env: gemfile_env(dir)) >> succeeded

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "lock is a no-op for an empty declaration set" do
    Given "no bundler declarations"
    dir = Dir.mktmpdir("dev-bundler-locker-test-")
    shadowenv_exec = Dev::Deps::ShadowenvExec.new(project_root: dir)
    locker = build_locker(dir, shadowenv_exec)

    When "locking"
    locker.lock([])

    Then "no Gemfile is written"
    0 * shadowenv_exec.capture3
    !(Pathname(dir) / "Gemfile").exist?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "lock raises LockError when bundle lock fails" do
    Given "a bundle lock that will fail"
    dir = Dir.mktmpdir("dev-bundler-locker-test-")
    shadowenv_exec = Dev::Deps::ShadowenvExec.new(project_root: dir)
    locker = build_locker(dir, shadowenv_exec)

    When "locking"
    locker.lock(bundler_declarations { gem "ffi" })

    Then
    _ * shadowenv_exec.capture3 >> ["", "could not resolve", exit_status(1)]
    raises Dev::Deps::BundlerLocker::LockError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the seam defaults to the project's own shadowenv" do
    Given "a project root, and a seam for the constructor to answer with"
    dir = Dir.mktmpdir("dev-bundler-locker-test-")
    seam = Dev::Deps::ShadowenvExec.new(project_root: dir)

    When "constructing without an explicit seam"
    Dev::Deps::BundlerLocker.new(project_root: dir)

    Then "the default seam was built over the project root"
    1 * Dev::Deps::ShadowenvExec.new(project_root: Pathname(dir)) >> seam

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

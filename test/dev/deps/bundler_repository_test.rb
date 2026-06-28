# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps"
require "dev/deps/bundler_repository"
require "dev/deps/dependency_declaration"
require "open3"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::BundlerRepositoryTest < Minitest::Test
  LOCKFILE_FIXTURE = <<~LOCK
    GEM
      remote: https://rubygems.org/
      specs:
        ffi (1.17.0)
        minitest (5.22.0)

    PLATFORMS
      ruby

    DEPENDENCIES
      ffi (~> 1.17)
      minitest (~> 5.0)

    CHECKSUMS
      ffi (1.17.0) sha256=aaa111
      minitest (5.22.0) sha256=bbb222

    BUNDLED WITH
       2.5.0
  LOCK

  def bundler_declarations(&block)
    Dev::Deps.define(&block).declarations.select { |d| d.integration == :bundler }
  end

  test "prepare generates a Gemfile mapping dev groups to bundler groups" do
    Given "gem declarations in the default and test groups"
    dir = Dir.mktmpdir("dev-bundler-repo-test-")
    (Pathname(dir) / "Gemfile.lock").write(LOCKFILE_FIXTURE)
    repo = Dev::Deps::BundlerRepository.new(project_root: dir, ruby_version_requirement: "~> 4.0")
    decls = bundler_declarations do
      gem "ffi", "~> 1.17"
      group :test do
        gem "minitest", "~> 5.0"
      end
    end
    Open3.stubs(:capture3).returns(["", "", stub(success?: true)])

    When "preparing the repository"
    repo.prepare(decls)
    gemfile = (Pathname(dir) / "Gemfile").read

    Then "the Gemfile pins the source, ruby, default gem, and grouped gem"
    gemfile.include?(%(source "https://rubygems.org"))
    gemfile.include?(%(ruby "~> 4.0"))
    gemfile.include?(%(gem "ffi", "~> 1.17"))
    gemfile.include?("group :test do")
    gemfile.include?(%(  gem "minitest", "~> 5.0"))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "fetch returns the locked version and checksum for a declared gem" do
    Given "a prepared repository"
    dir = Dir.mktmpdir("dev-bundler-repo-test-")
    (Pathname(dir) / "Gemfile.lock").write(LOCKFILE_FIXTURE)
    repo = Dev::Deps::BundlerRepository.new(project_root: dir)
    decls = bundler_declarations { gem "ffi", "~> 1.17" }
    Open3.stubs(:capture3).returns(["", "", stub(success?: true)])
    repo.prepare(decls)

    When "fetching the declared gem"
    dep = repo.fetch("name" => "ffi", "integration" => "bundler", "group" => "app")

    Then "it carries the pinned version and checksum from the lockfile"
    dep.name == "ffi"
    dep.integration == :bundler
    dep.version == "1.17.0"
    dep.hash == "SHA256=aaa111"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "fetch raises when the gem is missing from the lockfile" do
    Given "a prepared repository whose lockfile lacks the gem"
    dir = Dir.mktmpdir("dev-bundler-repo-test-")
    (Pathname(dir) / "Gemfile.lock").write(LOCKFILE_FIXTURE)
    repo = Dev::Deps::BundlerRepository.new(project_root: dir)
    Open3.stubs(:capture3).returns(["", "", stub(success?: true)])
    repo.prepare(bundler_declarations { gem "ffi" })

    When "fetching an undeclared gem"
    error = assert_raises(Dev::Deps::BundlerRepository::MissingGemError) do
      repo.fetch("name" => "absent", "integration" => "bundler", "group" => "app")
    end

    Then "the error names the missing gem"
    error.message.include?("absent")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "prepare raises LockError when bundle lock fails" do
    Given "a repository whose bundle lock will fail"
    dir = Dir.mktmpdir("dev-bundler-repo-test-")
    repo = Dev::Deps::BundlerRepository.new(project_root: dir)
    Open3.stubs(:capture3).returns(["", "could not resolve", stub(success?: false)])

    When "preparing the repository"
    error = assert_raises(Dev::Deps::BundlerRepository::LockError) do
      repo.prepare(bundler_declarations { gem "ffi" })
    end

    Then "the error surfaces the bundler failure"
    error.message.include?("bundle lock failed")

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

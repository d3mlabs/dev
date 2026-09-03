# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/bundler_repository"
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

  test "find reports the locked pin as a singleton universe" do
    Given "a project with a materialized Gemfile.lock"
    dir = Dir.mktmpdir("dev-bundler-repo-test-")
    (Pathname(dir) / "Gemfile.lock").write(LOCKFILE_FIXTURE)
    repo = Dev::Deps::BundlerRepository.new(project_root: dir)

    When "finding a declared gem"
    package = repo.find(Dev::Deps::PackageId.new(integration: :bundler, name: "ffi"))

    Then "one version — the joint solve's choice — with the CHECKSUMS digest"
    package.versions.map(&:version) == ["1.17.0"]
    package.version("1.17.0").digest == "SHA256=aaa111"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "find raises MissingGemError, a PackageNotFoundError, for unlocked gems" do
    Given "a lockfile lacking the gem"
    dir = Dir.mktmpdir("dev-bundler-repo-test-")
    (Pathname(dir) / "Gemfile.lock").write(LOCKFILE_FIXTURE)
    repo = Dev::Deps::BundlerRepository.new(project_root: dir)

    When "finding an unlocked gem"
    repo.find(Dev::Deps::PackageId.new(integration: :bundler, name: "absent"))

    Then
    raises Dev::Deps::Repository::PackageNotFoundError

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/bundler_integration"
require "dev/deps/bundler_repository"
require "dev/deps/cache"
require "dev/deps/dependency"
require "open3"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::BundlerIntegrationTest < Minitest::Test
  def build_integration(dir)
    Dev::Deps::BundlerIntegration.new(
      repository: Dev::Deps::BundlerRepository.new(project_root: dir),
      cache: Dev::Deps::Cache.new(cache_dir: dir),
      project_root: dir,
    )
  end

  def gem_dep(name)
    Dev::Deps::Dependency.new(name: name, integration: :bundler, group: :app,
      version: "1.0.0", hash: nil, metadata: {})
  end

  test "install_all runs a frozen bundle install against the generated Gemfile" do
    Given "a bundler integration with one locked gem"
    dir = Dir.mktmpdir("dev-bundler-int-test-")
    integration = build_integration(dir)
    gemfile = (Pathname(dir) / "Gemfile").to_s
    Open3.stubs(:capture3).with("bundle", "--version").returns(["Bundler version 2.5.0", "", stub(success?: true)])
    Open3.expects(:capture3)
         .with({ "BUNDLE_GEMFILE" => gemfile, "BUNDLE_FROZEN" => "true" }, "bundle", "install", chdir: dir)
         .returns(["", "", stub(success?: true)])

    When "installing all dependencies"
    integration.install_all([gem_dep("ffi")])

    Then "bundle install was dispatched against the project root"
    true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all is a no-op when there are no gems" do
    Given "a bundler integration and no gems"
    dir = Dir.mktmpdir("dev-bundler-int-test-")
    integration = build_integration(dir)
    Open3.expects(:capture3).never

    When "installing an empty dependency set"
    integration.install_all([])

    Then "no bundler command is run"
    true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all raises InstallError when bundle install fails" do
    Given "a bundler integration whose install fails"
    dir = Dir.mktmpdir("dev-bundler-int-test-")
    integration = build_integration(dir)
    Open3.stubs(:capture3).with("bundle", "--version").returns(["Bundler version 2.5.0", "", stub(success?: true)])
    Open3.stubs(:capture3).with(anything, "bundle", "install", chdir: dir).returns(["", "frozen mismatch", stub(success?: false)])

    When "installing all dependencies"
    error = assert_raises(Dev::Deps::BundlerIntegration::InstallError) do
      integration.install_all([gem_dep("ffi")])
    end

    Then "the error surfaces the bundler failure"
    error.message.include?("bundle install failed")

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

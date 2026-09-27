# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/bundler_integration"
require "dev/deps/bundler_repository"
require "dev/deps/cache"
require "dev/deps/dependency"
require "dev/deps/shadowenv_exec"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::BundlerIntegrationTest < Minitest::Test
  # Every bundler subprocess goes through the ShadowenvExec seam — the
  # project's provisioned Ruby, dev's own gem env scrubbed — so these tests
  # assert the messages sent to it rather than the raw process spawn.
  def build_integration(dir, shadowenv_exec)
    Dev::Deps::BundlerIntegration.new(
      repository: Dev::Deps::BundlerRepository.new(project_root: dir),
      cache: Dev::Deps::Cache.new(cache_dir: dir),
      project_root: dir,
      shadowenv_exec: shadowenv_exec,
    )
  end

  def gem_dep(name)
    Dev::Deps::Dependency.new(name: name, integration: :bundler, group: :app,
      version: "1.0.0", hash: nil, metadata: {})
  end

  def succeeded
    ["", "", stub(success?: true)]
  end

  def failed(err)
    ["", err, stub(success?: false)]
  end

  test "install_all runs a frozen bundle install through the project's shadowenv seam" do
    Given "a bundler integration with one locked gem and bundler present"
    dir = Dir.mktmpdir("dev-bundler-int-test-")
    shadowenv_exec = Dev::Deps::ShadowenvExec.new(project_root: dir)
    shadowenv_exec.stubs(:capture3).with("bundle", "--version").returns(succeeded)
    integration = build_integration(dir, shadowenv_exec)

    When "installing all dependencies"
    integration.install_all([gem_dep("ffi")])

    Then "bundle install is dispatched frozen against the generated Gemfile"
    1 * shadowenv_exec.capture3(
      "bundle", "install",
      env: { "BUNDLE_GEMFILE" => "#{dir}/Gemfile", "BUNDLE_FROZEN" => "true" },
    ) >> succeeded

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all installs bundler through the seam when the provisioned Ruby lacks it" do
    Given "a bundler integration whose shadowenv Ruby has no bundler"
    dir = Dir.mktmpdir("dev-bundler-int-test-")
    shadowenv_exec = Dev::Deps::ShadowenvExec.new(project_root: dir)
    shadowenv_exec.stubs(:capture3).with("bundle", "--version").returns(failed("command not found"))
    shadowenv_exec.stubs(:capture3).with("bundle", "install", env: anything).returns(succeeded)
    integration = build_integration(dir, shadowenv_exec)

    When "installing all dependencies"
    integration.install_all([gem_dep("ffi")])

    Then "bundler is installed into the provisioned Ruby, not the host one"
    1 * shadowenv_exec.capture3("gem", "install", "bundler", "--no-document") >> succeeded

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all raises BundlerMissingError when bundler cannot be installed" do
    Given "a bundler integration whose bundler install fails"
    dir = Dir.mktmpdir("dev-bundler-int-test-")
    shadowenv_exec = Dev::Deps::ShadowenvExec.new(project_root: dir)
    shadowenv_exec.stubs(:capture3).with("bundle", "--version").returns(failed("command not found"))
    shadowenv_exec.stubs(:capture3).with("gem", "install", "bundler", "--no-document").returns(failed("no network"))
    integration = build_integration(dir, shadowenv_exec)

    When "installing all dependencies"
    error = assert_raises(Dev::Deps::BundlerIntegration::BundlerMissingError) do
      integration.install_all([gem_dep("ffi")])
    end

    Then "the error surfaces the gem install failure"
    error.message.include?("no network")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all is a no-op when there are no gems" do
    Given "a bundler integration and no gems"
    dir = Dir.mktmpdir("dev-bundler-int-test-")
    shadowenv_exec = Dev::Deps::ShadowenvExec.new(project_root: dir)
    integration = build_integration(dir, shadowenv_exec)

    When "installing an empty dependency set"
    integration.install_all([])

    Then "no bundler command is run"
    0 * shadowenv_exec.capture3(any_parameters)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all raises InstallError when bundle install fails" do
    Given "a bundler integration whose install fails"
    dir = Dir.mktmpdir("dev-bundler-int-test-")
    shadowenv_exec = Dev::Deps::ShadowenvExec.new(project_root: dir)
    shadowenv_exec.stubs(:capture3).with("bundle", "--version").returns(succeeded)
    shadowenv_exec.stubs(:capture3).with("bundle", "install", env: anything).returns(failed("frozen mismatch"))
    integration = build_integration(dir, shadowenv_exec)

    When "installing all dependencies"
    error = assert_raises(Dev::Deps::BundlerIntegration::InstallError) do
      integration.install_all([gem_dep("ffi")])
    end

    Then "the error surfaces the bundler failure"
    error.message.include?("bundle install failed")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "builds its own seam on the project root when none is injected" do
    Given "a bundler integration constructed the way the registry does, with only a project root"
    dir = Dir.mktmpdir("dev-bundler-int-test-")
    integration = Dev::Deps::BundlerIntegration.new(
      repository: Dev::Deps::BundlerRepository.new(project_root: dir),
      cache: Dev::Deps::Cache.new(cache_dir: dir),
      project_root: dir,
    )
    Dev::Deps::ShadowenvExec.any_instance.stubs(:capture3).with("bundle", "--version").returns(succeeded)

    When "installing all dependencies"
    integration.install_all([gem_dep("ffi")])

    Then "bundle install still goes through a ShadowenvExec"
    1 * Dev::Deps::ShadowenvExec.any_instance.capture3("bundle", "install", env: anything) >> succeeded

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

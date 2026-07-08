# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/pip_integration"
require "shadowenv_python"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::PipIntegrationTest < Minitest::Test
  def dep(name, version)
    Dev::Deps::Dependency.new(
      name: name, integration: :pip, group: :anatomy,
      version: version, hash: "SHA256=abc", metadata: {},
    )
  end

  test "install_all is a no-op when there are no pip deps" do
    Given "an integration with an empty dep list"
    tmpdir = Dir.mktmpdir("pip-integration-")
    integration = Dev::Deps::PipIntegration.new(repository: nil, cache: nil, project_root: tmpdir, python_version: "3.12")

    Expect "nothing is installed and no venv is required"
    integration.install_all([]).nil?

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "install_all raises when pip deps exist but no python version is set" do
    Given "an integration with deps but a nil python version"
    tmpdir = Dir.mktmpdir("pip-integration-")
    integration = Dev::Deps::PipIntegration.new(repository: nil, cache: nil, project_root: tmpdir, python_version: nil)

    When "installing"
    error = assert_raises(Dev::Deps::PipIntegration::MissingVersionError) do
      integration.install_all([dep("totalsegmentator", "2.0.5")])
    end

    Then "the error explains the missing python directive"
    assert_includes error.message, "python"

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "install_all ensures the venv and pip-installs each pinned dep" do
    Given "an integration with one pinned dep and a stubbed venv + pip"
    tmpdir = Dir.mktmpdir("pip-integration-")
    integration = Dev::Deps::PipIntegration.new(repository: nil, cache: nil, project_root: tmpdir, python_version: "3.12")
    ShadowenvPython.stubs(:ensure_venv!).returns(File.join(tmpdir, ".venv"))
    ok = stub(success?: true)

    When "installing"
    integration.install_all([dep("totalsegmentator", "2.0.5")])

    Then "pip install is invoked with the exact version pin"
    1 * Open3.capture3(includes(".venv/bin/pip"), "install", "totalsegmentator==2.0.5") >> ["", "", ok]

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end
end

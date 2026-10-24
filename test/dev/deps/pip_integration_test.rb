# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/local_store"
require "dev/deps/pip_integration"
require "dev/shadowenv_python"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::PipIntegrationTest < Minitest::Test
  def dep(name, version)
    Dev::Deps::Dependency.new(
      name: name, integration: :pip, group: :anatomy,
      version: version, hash: "SHA256=abc", metadata: {},
    )
  end

  # The project venv as the python pin's activation leaves it.
  def lay_venv(dir)
    python = File.join(dir, Dev::ShadowenvPython::VENV_DIR, "bin", "python")
    FileUtils.mkdir_p(File.dirname(python))
    File.write(python, "#!/bin/sh\nexit 0\n")
    FileUtils.chmod(0o755, python)
    python
  end

  test "install_all is a no-op when there are no pip deps" do
    Given "an integration with an empty dep list"
    tmpdir = Dir.mktmpdir("pip-integration-")
    integration = Dev::Deps::PipIntegration.new(repository: nil, store: nil, project_root: tmpdir)

    When "installing an empty dep list"
    integration.install_all([])

    Then "nothing is installed and nothing is created"
    Dir.children(tmpdir).empty?

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "install_all raises when pip deps exist but the project has no venv — no python pin was installed" do
    Given "an integration with deps over a project without a .venv"
    tmpdir = Dir.mktmpdir("pip-integration-")
    integration = Dev::Deps::PipIntegration.new(repository: nil, store: nil, project_root: tmpdir)

    When "installing"
    integration.install_all([dep("totalsegmentator", "2.0.5")])

    Then "the error names the python directive that would have built the venv"
    error = raises Dev::Deps::PipIntegration::MissingVenvError
    error.message.include?("python")
    error.message.include?(".venv")

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "install_all pip-installs each pinned dep into the project venv, caching wheels in the store's pip tool cache" do
    Given "an integration with one pinned dep and the venv the python pin's activation built"
    tmpdir = Dir.mktmpdir("pip-integration-")
    python = lay_venv(tmpdir)
    integration = Dev::Deps::PipIntegration.new(
      repository: nil, store: Dev::Deps::LocalStore.new(data_root: tmpdir), project_root: tmpdir,
    )
    ok = stub(success?: true)

    When "installing"
    integration.install_all([dep("totalsegmentator", "2.0.5")])

    Then "pip install is invoked via the venv python with the exact version pin, PIP_CACHE_DIR in the store"
    1 * Open3.capture3(
      { "PIP_CACHE_DIR" => "#{tmpdir}/tool-caches/pip" },
      python, "-m", "pip", "install", "totalsegmentator==2.0.5",
    ) >> ["", "", ok]

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end
end

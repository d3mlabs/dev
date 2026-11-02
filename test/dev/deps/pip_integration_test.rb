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

  # A venv from before venvs lived in the store: a plain directory in the
  # project, for one side of the build container. Returns its python.
  def lay_venv(dir, venv_dir: Dev::ShadowenvPython::HOST_VENV_DIR)
    lay_venv_at(File.join(dir, venv_dir))
  end

  # The venv as the python pin's activation leaves it: built in the store
  # under `dir`, with the project's venv link pointing at it. Returns the
  # store venv's python.
  def lay_stored_venv(dir, venv_dir: Dev::ShadowenvPython::HOST_VENV_DIR)
    stored = File.join(dir, "venv", "proj", "host", "3.12.8")
    python = lay_venv_at(stored)
    File.symlink(stored, File.join(dir, venv_dir))
    python
  end

  def lay_venv_at(venv)
    python = File.join(venv, "bin", "python")
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

  test "install_all pip-installs each pinned dep into the store venv the project's .venv links at, through the venv's own path, caching wheels in the store's pip tool cache" do
    Given "an integration with one pinned dep and the venv the python pin's activation built in the store and linked"
    tmpdir = Dir.mktmpdir("pip-integration-")
    python = lay_stored_venv(tmpdir)
    integration = Dev::Deps::PipIntegration.new(
      repository: nil, store: Dev::Deps::LocalStore.new(data_root: tmpdir), project_root: tmpdir,
    )
    ok = stub(success?: true)

    When "installing"
    integration.install_all([dep("totalsegmentator", "2.0.5")])

    Then "pip install is invoked via the store venv's python — not the link's — with the exact version pin, PIP_CACHE_DIR in the store"
    1 * Open3.capture3(
      { "PIP_CACHE_DIR" => "#{tmpdir}/tool-caches/pip" },
      python, "-m", "pip", "install", "totalsegmentator==2.0.5",
    ) >> ["", "", ok]

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "install_all installs into a plain-directory venv in the project, from before venvs lived in the store" do
    Given "an integration with one pinned dep over a project whose .venv is a directory"
    tmpdir = Dir.mktmpdir("pip-integration-")
    python = lay_venv(tmpdir)
    integration = Dev::Deps::PipIntegration.new(
      repository: nil, store: Dev::Deps::LocalStore.new(data_root: tmpdir), project_root: tmpdir,
    )
    ok = stub(success?: true)

    When "installing"
    integration.install_all([dep("totalsegmentator", "2.0.5")])

    Then "pip install is invoked via that venv's python"
    1 * Open3.capture3(anything, python, "-m", "pip", "install", "totalsegmentator==2.0.5") >> ["", "", ok]

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "inside the build container, install_all installs into the container's own venv, not the host's" do
    Given "a project with both sides' venvs and an integration running inside the container"
    tmpdir = Dir.mktmpdir("pip-integration-")
    lay_stored_venv(tmpdir)
    container_python = lay_venv(tmpdir, venv_dir: Dev::ShadowenvPython::CONTAINER_VENV_DIR)
    integration = Dev::Deps::PipIntegration.new(
      repository: nil, store: Dev::Deps::LocalStore.new(data_root: tmpdir), project_root: tmpdir, inside_container: true,
    )
    ok = stub(success?: true)

    When "installing"
    integration.install_all([dep("totalsegmentator", "2.0.5")])

    Then "pip runs under the container venv's python"
    1 * Open3.capture3(anything, container_python, "-m", "pip", "install", "totalsegmentator==2.0.5") >> ["", "", ok]

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "inside the build container, a host-only venv does not satisfy install_all; the error names the container's path" do
    Given "a project whose host side built its venv, and an integration running inside the container"
    tmpdir = Dir.mktmpdir("pip-integration-")
    lay_venv(tmpdir)
    integration = Dev::Deps::PipIntegration.new(repository: nil, store: nil, project_root: tmpdir, inside_container: true)

    When "installing"
    integration.install_all([dep("totalsegmentator", "2.0.5")])

    Then "the error names the venv this side runs"
    error = raises Dev::Deps::PipIntegration::MissingVenvError
    error.message.include?(File.join(tmpdir, Dev::ShadowenvPython::CONTAINER_VENV_DIR))

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end
end

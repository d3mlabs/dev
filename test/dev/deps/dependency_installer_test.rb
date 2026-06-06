# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/dependency_installer"
require "dev/deps/lockfile"
require "dev/deps/dependency"
require "dev/deps/integration"
require "tmpdir"

class RecordingIntegration < Dev::Deps::Integration
  attr_reader :installed_deps

  def initialize
    @installed_deps = []
  end

  def install_all(dependencies)
    @installed_deps.concat(dependencies)
  end
end

transform!(RSpock::AST::Transformation)
class Dev::Deps::DependencyInstallerTest < Minitest::Test
  test "install reads lockfiles and dispatches to integrations" do
    Given "a lockfile with one cmake dep"
    dir = Dir.mktmpdir("installer-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: Pathname(dir))
    deps = [
      Dev::Deps::Dependency.new(name: "boost", integration: :cmake, group: :app,
                                version: "1.90.0", hash: "SHA256=aaa", metadata: {}),
    ]
    lockfile.lock(deps)
    cmake_integration = RecordingIntegration.new
    installer = Dev::Deps::DependencyInstaller.new(
      lockfile:, integrations: { cmake: cmake_integration },
    )

    When "running install"
    installer.install

    Then "cmake integration received the dep"
    cmake_integration.installed_deps.size == 1
    cmake_integration.installed_deps[0].name == "boost"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install dispatches build group before others" do
    Given "lockfiles with build and app deps"
    dir = Dir.mktmpdir("installer-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: Pathname(dir))
    deps = [
      Dev::Deps::Dependency.new(name: "boost", integration: :cmake, group: :app,
                                version: "1.90.0", hash: "SHA256=aaa", metadata: {}),
      Dev::Deps::Dependency.new(name: "ccache", integration: :brew, group: :build,
                                version: "4.10", hash: "SHA256=bbb", metadata: {}),
    ]
    lockfile.lock(deps)

    install_order = []
    cmake_int = RecordingIntegration.new
    brew_int = RecordingIntegration.new

    cmake_int.define_singleton_method(:install_all) do |dependencies|
      install_order << :cmake
      @installed_deps.concat(dependencies)
    end
    brew_int.define_singleton_method(:install_all) do |dependencies|
      install_order << :brew
      @installed_deps.concat(dependencies)
    end

    installer = Dev::Deps::DependencyInstaller.new(
      lockfile:, integrations: { cmake: cmake_int, brew: brew_int },
    )

    When "running install"
    installer.install

    Then "build (brew) ran before app (cmake)"
    install_order == [:brew, :cmake]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install filters deps by env when env is set" do
    Given "deps with env metadata"
    dir = Dir.mktmpdir("installer-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: Pathname(dir))
    deps = [
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build,
                                version: "3.31", hash: "SHA256=aaa", metadata: {}),
      Dev::Deps::Dependency.new(name: "ruby", integration: :brew, group: :build,
                                version: "4.0", hash: "SHA256=bbb",
                                metadata: { "env" => "ci" }),
      Dev::Deps::Dependency.new(name: "powershell", integration: :brew, group: :build,
                                version: "7.4", hash: "SHA256=ccc",
                                metadata: { "env" => "dev" }),
    ]
    lockfile.lock(deps)
    brew_int = RecordingIntegration.new
    installer = Dev::Deps::DependencyInstaller.new(
      lockfile:, integrations: { brew: brew_int },
    )

    When "installing for ci env"
    installer.install(env: "ci")

    Then "only cmake (no env) and ruby (ci env) are installed"
    names = brew_int.installed_deps.map(&:name).sort
    names == ["cmake", "ruby"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install skips integration types with no registered integration" do
    Given "a lockfile with an unregistered integration type"
    dir = Dir.mktmpdir("installer-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: Pathname(dir))
    deps = [
      Dev::Deps::Dependency.new(name: "foo", integration: :unknown, group: :app,
                                version: "1.0", hash: "SHA256=aaa", metadata: {}),
    ]
    lockfile.lock(deps)
    installer = Dev::Deps::DependencyInstaller.new(lockfile:, integrations: {})

    When "running install with no matching integration"
    installer.install

    Then "no error raised"
    true

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

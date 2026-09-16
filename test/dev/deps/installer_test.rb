# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/installer"
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
class Dev::Deps::InstallerTest < Minitest::Test
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
    installer = Dev::Deps::Installer.new(
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

  test "install dispatches types sharing one integration instance in a single call" do
    Given "cmake and url deps both wired to one integration instance"
    dir = Dir.mktmpdir("installer-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: Pathname(dir))
    deps = [
      Dev::Deps::Dependency.new(name: "cereal", integration: :cmake, group: :app,
        version: "sha1", hash: nil, metadata: {}),
      Dev::Deps::Dependency.new(name: "boost", integration: :url, group: :app,
        version: nil, hash: "SHA256=aaa", metadata: {}),
    ]
    lockfile.lock(deps)

    shared = RecordingIntegration.new
    call_batches = []
    shared.define_singleton_method(:install_all) do |dependencies|
      call_batches << dependencies.map(&:name)
      @installed_deps.concat(dependencies)
    end
    installer = Dev::Deps::Installer.new(
      lockfile:, integrations: { cmake: shared, url: shared },
    )

    When "running install"
    installer.install

    Then "one install_all call with the union — batch artifacts (deps.cmake) stay whole"
    call_batches == [["cereal", "boost"]]

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

    installer = Dev::Deps::Installer.new(
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
    installer = Dev::Deps::Installer.new(
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

  test "install filters deps by host when host is set" do
    Given "deps with host metadata for both OSes"
    dir = Dir.mktmpdir("installer-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: Pathname(dir))
    deps = [
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build,
        version: "3.31", hash: "SHA256=aaa", metadata: {}),
      Dev::Deps::Dependency.new(name: "UnrealEngine", integration: :gh, group: :game,
        version: "5.8.0-wine-7", hash: nil,
        metadata: { "host" => "linux" }),
      Dev::Deps::Dependency.new(name: "UnrealEngineMac", integration: :gh, group: :editor,
        version: "5.8.0-mac-editor-1", hash: nil,
        metadata: { "host" => "darwin" }),
    ]
    lockfile.lock(deps)
    brew_int = RecordingIntegration.new
    gh_int = RecordingIntegration.new
    installer = Dev::Deps::Installer.new(
      lockfile:, integrations: { brew: brew_int, gh: gh_int },
    )

    When "installing for a darwin host"
    installer.install(host: "darwin")

    Then "the linux-hosted engine is filtered out; unhosted and darwin deps install"
    brew_int.installed_deps.map(&:name) == ["cmake"]
    gh_int.installed_deps.map(&:name) == ["UnrealEngineMac"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install dispatches bundler and luarocks deps to their integrations" do
    Given "a lockfile with a gem and a rock alongside a brew dep"
    dir = Dir.mktmpdir("installer-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: Pathname(dir))
    deps = [
      Dev::Deps::Dependency.new(name: "ffi", integration: :bundler, group: :app,
        version: "1.17.0", hash: nil, metadata: {}),
      Dev::Deps::Dependency.new(name: "luaunit", integration: :luarocks, group: :test,
        version: "3.5-1", hash: "SHA256=aaa", metadata: {}),
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build,
        version: "3.31", hash: "SHA256=bbb", metadata: {}),
    ]
    lockfile.lock(deps)
    bundler_int = RecordingIntegration.new
    luarocks_int = RecordingIntegration.new
    brew_int = RecordingIntegration.new
    installer = Dev::Deps::Installer.new(
      lockfile:, integrations: { bundler: bundler_int, luarocks: luarocks_int, brew: brew_int },
    )

    When "running install"
    installer.install

    Then "each integration received only its own deps"
    bundler_int.installed_deps.map(&:name) == ["ffi"]
    luarocks_int.installed_deps.map(&:name) == ["luaunit"]
    brew_int.installed_deps.map(&:name) == ["cmake"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install still runs the remaining integrations when one raises" do
    Given "a failing brew integration and a healthy cmake integration"
    dir = Dir.mktmpdir("installer-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: Pathname(dir))
    deps = [
      Dev::Deps::Dependency.new(name: "wwise-cli", integration: :brew, group: :build,
        version: "1.0", hash: "SHA256=aaa", metadata: {}),
      Dev::Deps::Dependency.new(name: "googletest", integration: :cmake, group: :test,
        version: "sha1", hash: nil, metadata: {}),
    ]
    lockfile.lock(deps)
    brew_int = RecordingIntegration.new
    brew_int.define_singleton_method(:install_all) do |_dependencies|
      raise "Homebrew prefix is not writable"
    end
    cmake_int = RecordingIntegration.new
    installer = Dev::Deps::Installer.new(
      lockfile:, integrations: { brew: brew_int, cmake: cmake_int },
    )

    When "running install and capturing the aggregate error"
    error = nil
    begin
      installer.install
    rescue StandardError => e
      error = e
    end

    Then "cmake still installed its dep and the aggregate error names the brew failure"
    cmake_int.installed_deps.map(&:name) == ["googletest"]
    error.is_a?(Dev::Deps::Installer::InstallFailedError)
    error.message.include?("brew: Homebrew prefix is not writable")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install flattens an integration's per-dep failures into individual entries" do
    Given "an integration raising PartialInstallError for one of its two deps"
    dir = Dir.mktmpdir("installer-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: Pathname(dir))
    deps = [
      Dev::Deps::Dependency.new(name: "wwise-cli", integration: :brew, group: :build,
        version: "1.0", hash: "SHA256=aaa", metadata: {}),
      Dev::Deps::Dependency.new(name: "ccache", integration: :brew, group: :build,
        version: "4.10", hash: "SHA256=bbb", metadata: {}),
    ]
    lockfile.lock(deps)
    brew_int = RecordingIntegration.new
    brew_int.define_singleton_method(:install_all) do |_dependencies|
      raise Dev::Deps::Integration::PartialInstallError.new(
        [["wwise-cli", RuntimeError.new("no bottle available")]],
      )
    end
    installer = Dev::Deps::Installer.new(lockfile:, integrations: { brew: brew_int })

    When "running install and capturing the aggregate error"
    error = nil
    begin
      installer.install
    rescue StandardError => e
      error = e
    end

    Then "the entry names the failing dep, not just the integration"
    error.is_a?(Dev::Deps::Installer::InstallFailedError)
    error.entries == ["brew: wwise-cli — no bottle available"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install orders aggregate entries build wave first" do
    Given "a failing build-wave integration and a failing app-wave integration"
    dir = Dir.mktmpdir("installer-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: Pathname(dir))
    deps = [
      Dev::Deps::Dependency.new(name: "boost", integration: :cmake, group: :app,
        version: "1.90.0", hash: "SHA256=aaa", metadata: {}),
      Dev::Deps::Dependency.new(name: "ccache", integration: :brew, group: :build,
        version: "4.10", hash: "SHA256=bbb", metadata: {}),
    ]
    lockfile.lock(deps)
    brew_int = RecordingIntegration.new
    brew_int.define_singleton_method(:install_all) do |_dependencies|
      raise "build wave failure"
    end
    cmake_int = RecordingIntegration.new
    cmake_int.define_singleton_method(:install_all) do |_dependencies|
      raise "app wave failure"
    end
    installer = Dev::Deps::Installer.new(
      lockfile:, integrations: { brew: brew_int, cmake: cmake_int },
    )

    When "running install and capturing the aggregate error"
    error = nil
    begin
      installer.install
    rescue StandardError => e
      error = e
    end

    Then "root causes (build wave) come before derivative failures (later waves)"
    error.is_a?(Dev::Deps::Installer::InstallFailedError)
    error.entries == ["brew: build wave failure", "cmake: app wave failure"]

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
    installer = Dev::Deps::Installer.new(lockfile:, integrations: {})

    When "running install with no matching integration"
    installer.install

    Then "no error raised"
    true

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

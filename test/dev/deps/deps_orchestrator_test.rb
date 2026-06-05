# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/deps_orchestrator"
require "dev/deps/lockfile"
require "dev/deps/dependency"
require "dev/deps/dependency_declaration"
require "dev/deps/repository"
require "dev/deps/integration"
require "dev/deps/cache"
require "tmpdir"
require "yaml"

class StubResolverRepository < Dev::Deps::Repository
  def initialize(deps_by_name: {})
    @deps_by_name = deps_by_name
  end

  def fetch(id)
    @deps_by_name.fetch(id["name"])
  end
end

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
class Dev::Deps::DepsOrchestratorTest < Minitest::Test
  # --- resolve_dependencies ---

  test "resolve_dependencies resolves declarations and writes lockfiles" do
    Given "declarations and a stub repository"
    dir = Dir.mktmpdir("orchestrator-test-")
    boost = Dev::Deps::Dependency.new(name: "boost", integration: :cmake, group: :app,
                                      version: "1.90.0", hash: "SHA256=aaa", metadata: {})
    repo = StubResolverRepository.new(deps_by_name: { "boost" => boost })
    declarations = [
      Dev::Deps::DependencyDeclaration.new(name: "boost", integration: :cmake, group: :app),
    ]
    orchestrator = Dev::Deps::DepsOrchestrator.new(dir: Pathname(dir), repositories: { cmake: repo })

    When "running resolve_dependencies"
    orchestrator.resolve_dependencies(declarations)

    Then "deps.lock is written"
    File.exist?(File.join(dir, "deps.lock"))
    lockfile = Dev::Deps::Lockfile.new(dir: Pathname(dir))
    deps = lockfile.read
    deps.size == 1
    deps[0].name == "boost"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  # --- install_all ---

  test "install_all reads lockfiles and dispatches to integrations" do
    Given "a lockfile with one cmake dep"
    dir = Dir.mktmpdir("orchestrator-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: Pathname(dir))
    deps = [
      Dev::Deps::Dependency.new(name: "boost", integration: :cmake, group: :app,
                                version: "1.90.0", hash: "SHA256=aaa", metadata: {}),
    ]
    lockfile.lock(deps)
    cmake_integration = RecordingIntegration.new
    orchestrator = Dev::Deps::DepsOrchestrator.new(
      dir: Pathname(dir), integrations: { cmake: cmake_integration },
    )

    When "running install_all"
    orchestrator.install_all

    Then "cmake integration received the dep"
    cmake_integration.installed_deps.size == 1
    cmake_integration.installed_deps[0].name == "boost"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all dispatches build group before others" do
    Given "lockfiles with build and app deps"
    dir = Dir.mktmpdir("orchestrator-test-")
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

    orchestrator = Dev::Deps::DepsOrchestrator.new(
      dir: Pathname(dir), integrations: { cmake: cmake_int, brew: brew_int },
    )

    When "running install_all"
    orchestrator.install_all

    Then "build (brew) ran before app (cmake)"
    install_order == [:brew, :cmake]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all filters deps by env when env is set" do
    Given "deps with env metadata"
    dir = Dir.mktmpdir("orchestrator-test-")
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
    orchestrator = Dev::Deps::DepsOrchestrator.new(
      dir: Pathname(dir), integrations: { brew: brew_int },
    )

    When "installing for ci env"
    orchestrator.install_all(env: "ci")

    Then "only cmake (no env) and ruby (ci env) are installed"
    names = brew_int.installed_deps.map(&:name).sort
    names == ["cmake", "ruby"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all skips integration types with no registered integration" do
    Given "a lockfile with an unregistered integration type"
    dir = Dir.mktmpdir("orchestrator-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: Pathname(dir))
    deps = [
      Dev::Deps::Dependency.new(name: "foo", integration: :unknown, group: :app,
                                version: "1.0", hash: "SHA256=aaa", metadata: {}),
    ]
    lockfile.lock(deps)
    orchestrator = Dev::Deps::DepsOrchestrator.new(dir: Pathname(dir))

    When "running install_all with no matching integration"
    orchestrator.install_all

    Then "no error raised"
    true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  # --- detect_env ---

  test "detect_env returns dev on macOS without CI" do
    Given "non-CI, non-Linux environment"
    original_ci = ENV["CI"]
    ENV.delete("CI")

    When "detecting env"
    result = Dev::Deps::DepsOrchestrator.detect_env

    Then "result depends on platform"
    if RUBY_PLATFORM.include?("linux")
      result == "ci"
    else
      result == "dev"
    end

    Cleanup
    ENV["CI"] = original_ci if original_ci
  end

  test "detect_env returns ci when CI env var is set" do
    Given "CI=true"
    original_ci = ENV["CI"]
    ENV["CI"] = "true"

    When "detecting env"
    result = Dev::Deps::DepsOrchestrator.detect_env

    Then
    result == "ci"

    Cleanup
    ENV["CI"] = original_ci
  end
end

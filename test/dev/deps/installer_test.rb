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

# The host prerequisite (brew's role): its batch installs before every other.
class PrerequisiteIntegration < RecordingIntegration
  class << self
    def host_prerequisite?
      true
    end
  end
end

transform!(RSpock::AST::Transformation)
class Dev::Deps::InstallerTest < Minitest::Test
  # Shorthand: a locked pin with the given provenance.
  def pin(name, integration, group: :app, needed_by: nil)
    metadata = needed_by ? { "needed_by" => needed_by } : {}
    Dev::Deps::Dependency.new(name:, integration:, group:, version: "1.0", hash: nil, metadata:)
  end

  # Wire integrations that record the order install_all reached them.
  def recording(order, *symbols, prerequisite: [])
    symbols.to_h do |symbol|
      integration = prerequisite.include?(symbol) ? PrerequisiteIntegration.new : RecordingIntegration.new
      integration.define_singleton_method(:install_all) do |dependencies|
        order << symbol
        @installed_deps.concat(dependencies)
      end
      [symbol, integration]
    end
  end
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

  test "install orders a pin's integration before each integration the lock records as needing it" do
    Given "an xcode pin, and the xcodes formula it needs, locked after it with provenance"
    dir = Dir.mktmpdir("installer-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: Pathname(dir))
    lockfile.lock([
      pin("xcode", :xcode, group: :editor),
      pin("xcodes", :brew, group: :editor, needed_by: ["xcode"]),
    ])
    order = []
    installer = Dev::Deps::Installer.new(lockfile:, integrations: recording(order, :xcode, :brew))

    When "running install"
    installer.install

    Then "the needed formula's batch ran first, whatever the lock order"
    order == [:brew, :xcode]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install orders the host prerequisite before every other batch, needs or not" do
    Given "an app cmake dep locked before an unrelated prerequisite formula"
    dir = Dir.mktmpdir("installer-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: Pathname(dir))
    lockfile.lock([pin("boost", :cmake), pin("ccache", :brew, group: :build)])
    order = []
    installer = Dev::Deps::Installer.new(lockfile:, integrations: recording(order, :cmake, :brew, prerequisite: [:brew]))

    When "running install"
    installer.install

    Then "the prerequisite ran first"
    order == [:brew, :cmake]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install gives the group no ordering role: without edges, lock order stands" do
    Given "a build-group dep locked after an app-group dep, neither needing the other"
    dir = Dir.mktmpdir("installer-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: Pathname(dir))
    lockfile.lock([pin("boost", :cmake, group: :app), pin("UnrealEngine", :gh, group: :build)])
    order = []
    installer = Dev::Deps::Installer.new(lockfile:, integrations: recording(order, :cmake, :gh))

    When "running install"
    installer.install

    Then "nothing installs first because of its group name"
    order == [:cmake, :gh]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install follows a chain of needs across integrations" do
    Given "a custom integration needing an xcode pin, which needs the xcodes formula"
    dir = Dir.mktmpdir("installer-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: Pathname(dir))
    lockfile.lock([
      pin("Thing", :custom),
      pin("xcode", :xcode, needed_by: ["custom"]),
      pin("xcodes", :brew, needed_by: ["xcode"]),
    ])
    order = []
    installer = Dev::Deps::Installer.new(lockfile:, integrations: recording(order, :custom, :xcode, :brew))

    When "running install"
    installer.install

    Then "deepest need first"
    order == [:brew, :xcode, :custom]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install still installs a need whose user is not in the selection" do
    Given "the xcodes formula needed by xcode, with only the brew integration's pins selected"
    dir = Dir.mktmpdir("installer-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: Pathname(dir))
    lockfile.lock([pin("xcode", :xcode), pin("xcodes", :brew, needed_by: ["xcode"])])
    order = []
    installer = Dev::Deps::Installer.new(lockfile:, integrations: recording(order, :xcode, :brew))

    When "installing brew pins only"
    installer.install(integration_types: [:brew])

    Then "the formula installed; the edge to an unselected batch ordered nothing"
    order == [:brew]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install refuses a cycle in the needs graph" do
    Given "two integrations each needing a pin of the other"
    dir = Dir.mktmpdir("installer-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: Pathname(dir))
    lockfile.lock([pin("a-tool", :alpha, needed_by: ["beta"]), pin("b-tool", :beta, needed_by: ["alpha"])])
    order = []
    installer = Dev::Deps::Installer.new(lockfile:, integrations: recording(order, :alpha, :beta))

    When "running install"
    error = assert_raises(Dev::Deps::Installer::DependencyCycleError) { installer.install }

    Then "nothing was attempted and the error names the stuck integrations"
    order.empty?
    error.message.include?("alpha")
    error.message.include?("beta")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install refuses a self-need: a pin needed by its own integration" do
    Given "a brew pin the lock says brew needs"
    dir = Dir.mktmpdir("installer-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: Pathname(dir))
    lockfile.lock([pin("git", :brew, needed_by: ["brew"])])
    installer = Dev::Deps::Installer.new(lockfile:, integrations: recording([], :brew))

    When "running install"
    installer.install

    Then
    raises Dev::Deps::Installer::DependencyCycleError

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

  test "install orders aggregate entries in install order: a need's failure before its user's" do
    Given "a failing integration whose pin another failing integration needs"
    dir = Dir.mktmpdir("installer-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: Pathname(dir))
    lockfile.lock([pin("xcode", :xcode), pin("xcodes", :brew, needed_by: ["xcode"])])
    brew_int = RecordingIntegration.new
    brew_int.define_singleton_method(:install_all) do |_dependencies|
      raise "formula failure"
    end
    xcode_int = RecordingIntegration.new
    xcode_int.define_singleton_method(:install_all) do |_dependencies|
      raise "xcodes missing"
    end
    installer = Dev::Deps::Installer.new(
      lockfile:, integrations: { xcode: xcode_int, brew: brew_int },
    )

    When "running install and capturing the aggregate error"
    error = nil
    begin
      installer.install
    rescue StandardError => e
      error = e
    end

    Then "the root cause comes before the derivative failure"
    error.is_a?(Dev::Deps::Installer::InstallFailedError)
    error.entries == ["brew: formula failure", "xcode: xcodes missing"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install with groups: dispatches only deps in the named groups" do
    Given "a lockfile with a build-group brew dep and an app-group cmake dep"
    dir = Dir.mktmpdir("installer-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: Pathname(dir))
    lockfile.lock([
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build,
        version: "4.4.3", hash: nil, metadata: {}),
      Dev::Deps::Dependency.new(name: "boost", integration: :cmake, group: :app,
        version: "1.90.0", hash: "SHA256=aaa", metadata: {}),
    ])
    brew = RecordingIntegration.new
    cmake = RecordingIntegration.new
    installer = Dev::Deps::Installer.new(lockfile:, integrations: { brew:, cmake: })

    When "installing only the build group"
    installer.install(groups: [:build])

    Then "the build dep installed and the app dep did not"
    brew.installed_deps.map(&:name) == ["cmake"]
    cmake.installed_deps.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install with except: dispatches every dep outside the named groups" do
    Given "a lockfile with a build-group brew dep and an app-group cmake dep"
    dir = Dir.mktmpdir("installer-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: Pathname(dir))
    lockfile.lock([
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build,
        version: "4.4.3", hash: nil, metadata: {}),
      Dev::Deps::Dependency.new(name: "boost", integration: :cmake, group: :app,
        version: "1.90.0", hash: "SHA256=aaa", metadata: {}),
    ])
    brew = RecordingIntegration.new
    cmake = RecordingIntegration.new
    installer = Dev::Deps::Installer.new(lockfile:, integrations: { brew:, cmake: })

    When "installing everything except the build group"
    installer.install(except: [:build])

    Then "the app dep installed and the build dep did not"
    cmake.installed_deps.map(&:name) == ["boost"]
    brew.installed_deps.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install with integration_types: dispatches only deps of the named integrations" do
    Given "a build group mixing an image toolchain (brew) with a host-installed artifact (gh)"
    dir = Dir.mktmpdir("installer-test-")
    lockfile = Dev::Deps::Lockfile.new(dir: Pathname(dir))
    lockfile.lock([
      Dev::Deps::Dependency.new(name: "wwise-cli", integration: :brew, group: :build,
        version: "0.2.3", hash: nil, metadata: {}),
      Dev::Deps::Dependency.new(name: "UnrealEngine", integration: :gh, group: :build,
        version: "5.6.1", hash: nil, metadata: {}),
    ])
    brew = RecordingIntegration.new
    gh = RecordingIntegration.new
    installer = Dev::Deps::Installer.new(lockfile:, integrations: { brew:, gh: })

    When "installing the build group through brew only"
    installer.install(groups: [:build], integration_types: [:brew])

    Then "the toolchain installed and the engine stayed out"
    brew.installed_deps.map(&:name) == ["wwise-cli"]
    gh.installed_deps.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "select applies env, host, groups, except and integration types as one pure filter" do
    Given "deps spanning groups, hosts and envs"
    deps = [
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build,
        version: "4.4.3", hash: nil, metadata: {}),
      Dev::Deps::Dependency.new(name: "xcodes", integration: :brew, group: :build,
        version: "2.1.0", hash: nil, metadata: { "host" => "darwin" }),
      Dev::Deps::Dependency.new(name: "powershell", integration: :brew, group: :build,
        version: "7.4.0", hash: nil, metadata: { "env" => "ci" }),
      Dev::Deps::Dependency.new(name: "rake", integration: :bundler, group: :app,
        version: "13.0", hash: nil, metadata: {}),
      Dev::Deps::Dependency.new(name: "rspock", integration: :bundler, group: :test,
        version: "2.5", hash: nil, metadata: {}),
    ]

    Expect "each selection names exactly the deps it should"
    Dev::Deps::Installer.select(deps, env:, host:, groups:, except:, integration_types:).map(&:name) == names

    Where
    env   | host    | groups        | except   | integration_types | names
    nil   | nil     | nil           | []       | nil               | ["cmake", "xcodes", "powershell", "rake", "rspock"]
    "dev" | "linux" | nil           | []       | nil               | ["cmake", "rake", "rspock"]
    "ci"  | "linux" | [:build]      | []       | nil               | ["cmake", "powershell"]
    nil   | nil     | nil           | [:build] | nil               | ["rake", "rspock"]
    nil   | nil     | [:app, :test] | [:test]  | nil               | ["rake"]
    nil   | nil     | nil           | []       | [:bundler]        | ["rake", "rspock"]
    "ci"  | "linux" | [:build]      | []       | [:brew]           | ["cmake", "powershell"]
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

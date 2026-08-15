# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev"
require "dev/runner"
require "dev/credentials"
require "dev/deps/cmake_integration"
require "shadowenv_ruby"
require "stringio"
require "tempfile"
require "tmpdir"
require "fileutils"

transform!(RSpock::AST::Transformation)
class RunnerTest < Minitest::Test
  extend T::Sig
  include SorbetHelper

  test "run with empty argv prints usage" do
    Given "a Runner with a dev.yml"
    runner = build_runner(commands: { "up" => { "run" => "./bin/up.rb", "desc" => "Setup" } })
    out = StringIO.new

    When "we run with empty argv"
    runner.run([], ui: fake_ui, out: out)

    Then "usage is printed"
    out.string.include?("Usage: dev <command> [args...]")
    out.string.include?("Commands for testproject:")
    out.string.include?("up")
    out.string.include?("Setup")
  end

  test "run with --help prints usage" do
    Given "a Runner"
    runner = build_runner
    out = StringIO.new

    When "we run with --help"
    runner.run(["--help"], ui: fake_ui, out: out)

    Then "usage is printed"
    out.string.include?("Usage: dev <command> [args...]")
  end

  test "run with -h prints usage" do
    Given "a Runner"
    runner = build_runner
    out = StringIO.new

    When "we run with -h"
    runner.run(["-h"], ui: fake_ui, out: out)

    Then "usage is printed"
    out.string.include?("Usage: dev <command> [args...]")
  end

  test "run with unknown command prints error to stderr and exits 1" do
    Given "a Runner"
    runner = build_runner
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).once

    When "we run an unknown command"
    runner.run(["nonexistent"], ui: fake_ui)

    Then "error mentions the command name"
    $stderr.string.include?("nonexistent")
    $stderr.string.include?("dev --help")

    Cleanup
    $stderr = old_stderr
  end

  test "usage includes built-in update-deps command" do
    Given "a Runner with no project commands"
    runner = build_runner(commands: {})
    out = StringIO.new

    When "we print usage"
    runner.run([], ui: fake_ui, out: out)

    Then "update-deps is listed"
    out.string.include?("update-deps")
    out.string.include?("Resolve dependency constraints")
  end

  test "usage includes both built-in and project commands" do
    Given "a Runner with project commands"
    runner = build_runner(commands: {
      "test" => { "run" => "rspec", "desc" => "Run tests" },
      "up" => { "run" => "./bin/up.rb", "desc" => "Setup" },
    })
    out = StringIO.new

    When "we print usage"
    runner.run([], ui: fake_ui, out: out)

    Then "all commands appear"
    out.string.include?("update-deps")
    out.string.include?("test")
    out.string.include?("up")
  end

  test "usage includes reset-container when the build container persists" do
    Given "a Runner whose build container opts into persist"
    runner = build_runner(
      commands: {},
      build: { "container" => {
        "image" => "myapp-linux", "registry" => "myregistry", "persist" => true,
      } },
    )
    out = StringIO.new

    When "we print usage"
    runner.run([], ui: fake_ui, out: out)

    Then "the teardown command is listed"
    out.string.include?("reset-container")
  end

  test "reset-container is not registered without persist" do
    Given "a Runner with a non-persistent build container"
    runner = build_runner(
      commands: {},
      build: { "container" => { "image" => "myapp-linux", "registry" => "myregistry" } },
    )
    out = StringIO.new

    When "we print usage"
    runner.run([], ui: fake_ui, out: out)

    Then "no teardown command is listed"
    !out.string.include?("reset-container")
  end

  test "provide-image is registered (but hidden) when a build container is configured" do
    Given "a Runner with a build container"
    runner = build_runner(
      commands: {},
      build: { "container" => { "image" => "myapp-linux", "registry" => "myregistry" } },
    )
    registry = runner.instance_variable_get(:@registry)
    out = StringIO.new

    When "we print usage"
    runner.run([], ui: fake_ui, out: out)

    Then "the command is callable but omitted from usage"
    registry.lookup("provide-image").is_a?(Dev::BuiltinCommand)
    registry.lookup("provide-image").hidden?
    !out.string.include?("provide-image")
  end

  test "provide-image is not registered without a build container" do
    Given "a Runner without a build container"
    runner = build_runner(commands: {})

    When "we inspect the registry"
    registry = runner.instance_variable_get(:@registry)

    Then "the command is absent"
    !registry.all.key?("provide-image")
  end

  test "usage includes runner-setup when a runner block is declared" do
    Given "a Runner whose dev.yml declares a runner block"
    runner = build_runner(commands: {}, runner: { "labels" => "ue-engine" })
    out = StringIO.new

    When "we print usage"
    runner.run([], ui: fake_ui, out: out)

    Then "the runner-setup command is listed"
    out.string.include?("runner-setup")
  end

  test "runner-setup is not registered without a runner block" do
    Given "a Runner with no runner block"
    runner = build_runner(commands: {})
    out = StringIO.new

    When "we print usage"
    runner.run([], ui: fake_ui, out: out)

    Then "no runner-setup command is listed"
    !out.string.include?("runner-setup")
  end

  test "host integrations register a project-rooted cmake integration" do
    Given "a Runner"
    runner = build_runner
    root = Pathname.new(Dir.mktmpdir("runner-cmake-test-"))

    When "we build the host integrations for a project root"
    integrations = runner.send(:build_host_integrations, project_root: root)

    Then "cmake plus the newly-wired gems/luarocks/brew integrations are all host-installed"
    integrations[:cmake].is_a?(Dev::Deps::CmakeIntegration)
    integrations[:bundler].is_a?(Dev::Deps::BundlerIntegration)
    integrations[:luarocks].is_a?(Dev::Deps::LuaRocksIntegration)
    integrations[:brew].is_a?(Dev::Deps::BrewIntegration)

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "up is a builtin even when the project defines no up command" do
    Given "a Runner with no project commands"
    runner = build_runner(commands: {})
    out = StringIO.new

    When "we print usage"
    runner.run([], ui: fake_ui, out: out)

    Then "up is listed as the builtin dependency install"
    out.string.include?("up")
    out.string.include?("Install locked dependencies, then run the project's up command")
  end

  test "usage includes the cd builtin" do
    Given "a Runner with no project commands"
    runner = build_runner(commands: {})
    out = StringIO.new

    When "we print usage"
    runner.run([], ui: fake_ui, out: out)

    Then "cd is listed"
    out.string.include?("cd")
    out.string.include?("Jump to a checkout")
  end

  test "usage includes the clone builtin" do
    Given "a Runner with no project commands"
    runner = build_runner(commands: {})
    out = StringIO.new

    When "we print usage"
    runner.run([], ui: fake_ui, out: out)

    Then "clone is listed"
    out.string.include?("clone")
    out.string.include?("Clone a GitHub repo")
  end

  test "the clone builtin dispatches argv to the injected clone accessor" do
    Given "a Runner with a clone accessor expecting the argv"
    clone_accessor = typed_mock(Dev::Clone::Accessor)
    clone_accessor.expects(:run).with(["acme/widget"]).once
    runner = build_runner(commands: {}, clone_accessor: clone_accessor)

    When "we run dev clone"
    runner.run(["clone", "acme/widget"], ui: fake_ui)

    Then "the expectation on the accessor holds"
    true
  end

  test "the cd builtin dispatches argv to the injected cd accessor" do
    Given "a Runner with a cd accessor expecting the argv"
    cd_accessor = typed_mock(Dev::Cd::Accessor)
    cd_accessor.expects(:run).with(["widget"]).once
    runner = build_runner(commands: {}, cd_accessor: cd_accessor)

    When "we run dev cd"
    runner.run(["cd", "widget"], ui: fake_ui)

    Then "the expectation on the accessor holds"
    true
  end

  test "up ensures the dev cd shell hook (idempotently)" do
    Given "a Runner with no project up command and a hook installer expectation"
    hook_installer = typed_mock(Dev::Cd::HookInstaller)
    hook_installer.expects(:ensure_installed).once.returns(:already_present)
    staleness = fake_staleness
    runner = build_runner(commands: {}, hook_installer: hook_installer, staleness_provider: ->(_root) { staleness })
    runner.stubs(:install_locked_deps)

    When "we run up"
    runner.run(["up"], ui: fake_ui)

    Then "the expectation on the hook installer holds"
    true
  end

  test "a project up command overrides the builtin: install runs first, then the script" do
    Given "a Runner whose dev.yml defines up and a spy on both stages"
    original_cwd = Dir.pwd
    root = Pathname.new(Dir.mktmpdir("runner-up-order-"))
    Dev.stubs(:target_project_root).returns(root)
    staleness = fake_staleness
    runner = build_runner(
      commands: { "up" => { "run" => "./bin/up.rb", "desc" => "Setup", "container" => false } },
      hook_installer: stubbed_hook_installer,
      staleness_provider: ->(_root) { staleness },
    )
    runner.stubs(:resolve_ruby_version).returns("4.0.1")
    ShadowenvRuby.stubs(:ensure!)
    execution_order = []
    runner.stubs(:install_locked_deps).with {
      execution_order << :builtin_install
      true }
    # The project script's execution boundary is Kernel.system (wait mode);
    # spying there keeps the real ShellCommand -> CommandRunner path intact.
    Kernel.stubs(:system).with {
      execution_order << :project_script
      true }.returns(true)

    When "we run up"
    runner.run(["up"], ui: fake_ui)

    Then "OverriddenCommand super()-dispatches the builtin before the project script"
    execution_order == [:builtin_install, :project_script]

    Cleanup
    Dir.chdir(original_cwd)
    FileUtils.rm_rf(root)
  end

  # Regression for dev#85: a project-defined `up:` used to exec-replace the
  # dev process, so Runner#run never reached stamp_installed and the
  # staleness gate reported "never installed" forever.
  test "up with a project up command runs it spawn-and-wait and stamps installed" do
    Given "a Runner whose dev.yml defines up, pinned to an empty project root"
    original_cwd = Dir.pwd
    root = Pathname.new(Dir.mktmpdir("runner-up-stamp-"))
    Dev.stubs(:target_project_root).returns(root)
    staleness = fake_staleness
    staleness.expects(:stamp_installed!).once
    runner = build_runner(
      commands: { "up" => { "run" => "./bin/up.rb", "desc" => "Setup", "container" => false } },
      hook_installer: stubbed_hook_installer,
      staleness_provider: ->(_root) { staleness },
    )
    runner.stubs(:resolve_ruby_version).returns("4.0.1")
    runner.stubs(:install_locked_deps)
    # Provisioning's shell-out boundary; llvm/python provisioning no-op on an
    # empty project root.
    ShadowenvRuby.stubs(:ensure!)

    When "we run up"
    runner.run(["up"], ui: fake_ui)

    Then "the project script runs as a waited child, never via exec-replace"
    1 * Kernel.system(anything, "shadowenv", "exec", "--", "sh", "-c", includes("./bin/up.rb")) >> true
    0 * Kernel.exec(any_parameters)

    Cleanup
    Dir.chdir(original_cwd)
    FileUtils.rm_rf(root)
  end

  test "a failing project up command skips the stamp and exits with the child's status" do
    Given "a Runner whose dev.yml defines up, whose script exits 7"
    original_cwd = Dir.pwd
    root = Pathname.new(Dir.mktmpdir("runner-up-fail-"))
    Dev.stubs(:target_project_root).returns(root)
    staleness = fake_staleness
    staleness.expects(:stamp_installed!).never
    runner = build_runner(
      commands: { "up" => { "run" => "./bin/up.rb", "desc" => "Setup", "container" => false } },
      hook_installer: stubbed_hook_installer,
      staleness_provider: ->(_root) { staleness },
    )
    runner.stubs(:resolve_ruby_version).returns("4.0.1")
    runner.stubs(:install_locked_deps)
    ShadowenvRuby.stubs(:ensure!)
    Kernel.stubs(:system).returns(false)
    # Kernel.system is stubbed, so wait on a real child here to leave the
    # thread-local $? at exit status 7 — what a real failed child would set.
    Process.wait(Process.spawn("sh", "-c", "exit 7"))
    Kernel.expects(:exit).with(7).once
    # Guard: a regression to exec-replace would otherwise replace the test
    # process itself (Kernel.system above is stubbed, Kernel.exec is real).
    Kernel.expects(:exec).never

    When "we run up"
    runner.run(["up"], ui: fake_ui)

    Then "the expectations hold: no stamp, exit with the child's status"
    true

    Cleanup
    Dir.chdir(original_cwd)
    FileUtils.rm_rf(root)
  end

  test "generic project commands keep the exec tail-call" do
    Given "a Runner with a test command, pinned to an empty project root"
    original_cwd = Dir.pwd
    root = Pathname.new(Dir.mktmpdir("runner-exec-tail-"))
    Dev.stubs(:target_project_root).returns(root)
    runner = build_runner(commands: { "test" => { "run" => "./bin/test.sh", "desc" => "Run tests", "container" => false } })
    runner.stubs(:resolve_ruby_version).returns("4.0.1")
    ShadowenvRuby.stubs(:ensure!)

    When "we run a non-stamping command"
    runner.run(["test"], ui: fake_ui)

    Then "the command exec-replaces the process, never spawn-and-wait"
    1 * Kernel.exec(anything, "shadowenv", "exec", "--", "sh", "-c", includes("./bin/test.sh"))
    0 * Kernel.system(any_parameters)

    Cleanup
    Dir.chdir(original_cwd)
    FileUtils.rm_rf(root)
  end

  test "up resolves docker build arg credentials before executing" do
    Given "a Runner with build container build_args and an up command"
    original_cwd = Dir.pwd
    root = Pathname.new(Dir.mktmpdir("runner-up-creds-"))
    Dev.stubs(:target_project_root).returns(root)
    staleness = fake_staleness
    runner = build_runner(
      commands: { "up" => { "run" => "./bin/up.rb", "desc" => "Setup", "container" => false } },
      build: { "container" => {
        "image" => "myapp-linux", "registry" => "myregistry",
        "build_args" => { "WWISE_EMAIL" => "wwise/email" },
      } },
      hook_installer: stubbed_hook_installer,
      staleness_provider: ->(_root) { staleness },
    )
    runner.stubs(:resolve_ruby_version).returns("4.0.1")
    runner.stubs(:install_locked_deps)
    ShadowenvRuby.stubs(:ensure!)
    Kernel.stubs(:system).returns(true)

    When "we run up"
    runner.run(["up"], ui: fake_ui)

    Then "build args are resolved (prompting and storing on first run)"
    1 * Dev::Credentials.resolve_build_args({ "WWISE_EMAIL" => "wwise/email" })

    Cleanup
    Dir.chdir(original_cwd)
    FileUtils.rm_rf(root)
  end

  test "up without build container skips credential provisioning" do
    Given "a Runner without a build container"
    original_cwd = Dir.pwd
    root = Pathname.new(Dir.mktmpdir("runner-up-nocreds-"))
    Dev.stubs(:target_project_root).returns(root)
    staleness = fake_staleness
    runner = build_runner(
      commands: { "up" => { "run" => "./bin/up.rb", "desc" => "Setup" } },
      hook_installer: stubbed_hook_installer,
      staleness_provider: ->(_root) { staleness },
    )
    runner.stubs(:resolve_ruby_version).returns("4.0.1")
    runner.stubs(:install_locked_deps)
    ShadowenvRuby.stubs(:ensure!)
    Kernel.stubs(:system).returns(true)

    When "we run up"
    runner.run(["up"], ui: fake_ui)

    Then "credentials are never resolved"
    0 * Dev::Credentials.resolve_build_args(anything)

    Cleanup
    Dir.chdir(original_cwd)
    FileUtils.rm_rf(root)
  end

  test "non-up commands do not provision credentials eagerly" do
    Given "a Runner with build container build_args and a test command"
    # Pin the project root to an empty tmpdir so the staleness guard sees no
    # lockfiles — otherwise it digests the real dev checkout against
    # ~/.dev/state and aborts the run under CI (a fresh HOME has no stamp).
    original_cwd = Dir.pwd
    root = Pathname.new(Dir.mktmpdir("runner-non-up-"))
    Dev.stubs(:target_project_root).returns(root)
    runner = build_runner(
      commands: { "test" => { "run" => "./bin/test.sh", "desc" => "Run tests", "container" => false } },
      build: { "container" => {
        "image" => "myapp-linux", "registry" => "myregistry",
        "build_args" => { "WWISE_EMAIL" => "wwise/email" },
      } },
    )
    # The empty tmpdir declares no Ruby; pin resolution so the test never
    # shells out to brew for the Homebrew-Ruby fallback.
    runner.stubs(:resolve_ruby_version).returns("4.0.1")
    ShadowenvRuby.stubs(:ensure!)
    # A non-stamping command exec-replaces at the Kernel boundary.
    Kernel.stubs(:exec)

    When "we run a non-up command"
    runner.run(["test"], ui: fake_ui)

    Then "credentials are not resolved eagerly"
    0 * Dev::Credentials.resolve_build_args(anything)

    Cleanup
    Dir.chdir(original_cwd)
    FileUtils.rm_rf(root)
  end

  test "learnings dispatches the subcommand to the learnings accessor built for the project root" do
    Given "a Runner pinned to an empty project root, with a learnings accessor provider"
    root = Pathname.new(Dir.mktmpdir("runner-learnings-"))
    Dev.stubs(:target_project_root).returns(root)
    learnings_accessor = typed_mock(Dev::Learnings::Accessor)
    learnings_accessor.expects(:run).with(["status"]).once
    provided_roots = []
    runner = build_runner(commands: {}, learnings_accessor_provider: ->(project_root) {
      provided_roots << project_root
      learnings_accessor
    })
    runner.stubs(:resolve_ruby_version).returns("4.0.1")

    When "we run dev learnings status"
    runner.run(["learnings", "status"], ui: fake_ui)

    Then "the accessor was built for the project root and received the subcommand"
    provided_roots == [root]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "install-deps finishes by linking gem skills and syncing org learnings" do
    Given "a Runner pinned to an empty project root, with the installer stubbed"
    root = Pathname.new(Dir.mktmpdir("runner-install-deps-"))
    Dev.stubs(:target_project_root).returns(root)
    installer = typed_mock(Dev::Deps::DependencyInstaller)
    installer.stubs(:install)
    gem_skill_linker = typed_mock(Dev::Deps::GemSkillLinker)
    gem_skill_linker.expects(:link_all).once
    synchronizer = typed_mock(Dev::Learnings::Synchronizer)
    synchronizer.expects(:sync).with(project_root: root).once
    staleness = fake_staleness
    runner = build_runner(
      commands: {},
      dependency_installer_provider: ->(_lockfile, _integrations) { installer },
      gem_skill_linker_provider: ->(_root) { gem_skill_linker },
      learnings_synchronizer_provider: -> { synchronizer },
      staleness_provider: ->(_root) { staleness },
    )
    runner.stubs(:resolve_ruby_version).returns("4.0.1")
    ShadowenvRuby.stubs(:ensure!)

    When "we run install-deps"
    runner.run(["install-deps"], ui: fake_ui)

    Then "the expectations on both post-install hooks hold"
    true

    Cleanup
    FileUtils.rm_rf(root)
  end

  # Headless boxes (CI, runner services) reach install-deps before any
  # dev.yml command has run CommandRunner's provisioning — the builtin must
  # provision the toolchain itself or bundler installs against whatever
  # Ruby the service PATH happens to carry.
  test "install-deps provisions the shadowenv Ruby before installing" do
    Given "a Runner pinned to an empty project root, with the installer stubbed"
    root = Pathname.new(Dir.mktmpdir("runner-install-deps-ruby-"))
    Dev.stubs(:target_project_root).returns(root)
    installer = typed_mock(Dev::Deps::DependencyInstaller)
    installer.stubs(:install)
    gem_skill_linker = typed_mock(Dev::Deps::GemSkillLinker)
    gem_skill_linker.stubs(:link_all)
    synchronizer = typed_mock(Dev::Learnings::Synchronizer)
    synchronizer.stubs(:sync)
    staleness = fake_staleness
    runner = build_runner(
      commands: {},
      dependency_installer_provider: ->(_lockfile, _integrations) { installer },
      gem_skill_linker_provider: ->(_root) { gem_skill_linker },
      learnings_synchronizer_provider: -> { synchronizer },
      staleness_provider: ->(_root) { staleness },
    )
    runner.stubs(:resolve_ruby_version).returns("4.0.1")
    ShadowenvRuby.expects(:ensure!).with(ruby_version: "4.0.1", project_root: root).once

    When "we run install-deps"
    runner.run(["install-deps"], ui: fake_ui)

    Then "the expectation on the provisioning step holds"
    true

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "declared_ruby_version returns the dependencies.rb ruby directive" do
    Given "a project whose dependencies.rb declares ruby"
    root = Pathname.new(Dir.mktmpdir("runner-ruby-deps-"))
    File.write(root / "dependencies.rb", <<~RUBY)
      require "dev/deps"
      Dev::Deps.define { ruby "9.9.9" }
    RUBY
    Dev.stubs(:target_project_root).returns(root)
    runner = build_runner

    When "we read the declared ruby version"
    result = runner.send(:declared_ruby_version)

    Then "the dependencies.rb directive is used"
    result == "9.9.9"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "declared_ruby_version rejects the removed dev.yml ruby: key with a migration error" do
    Given "a project whose dev.yml still carries the removed ruby: key"
    root = Pathname.new(Dir.mktmpdir("runner-ruby-devyml-"))
    Dev.stubs(:target_project_root).returns(root)
    runner = build_runner(ruby: "4.0.1")

    When "we read the declared ruby version"
    runner.send(:declared_ruby_version)

    Then "the stale key is rejected, pointing at the dependencies.rb migration"
    raises Dev::Runner::UnsupportedDevYamlRubyError

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "declared_ruby_version ignores a config left over from a previously loaded manifest" do
    Given "a stale config from an earlier manifest load, and a project whose dependencies.rb never calls Dev::Deps.define (bootstrap constants)"
    Dev::Deps.define { ruby "9.9.9" }
    root = Pathname.new(Dir.mktmpdir("runner-ruby-stale-"))
    File.write(root / "dependencies.rb", "SOME_CONSTANT = 1 unless defined?(SOME_CONSTANT)\n")
    Dev.stubs(:target_project_root).returns(root)
    runner = build_runner

    When "we read the declared ruby version"
    result = runner.send(:declared_ruby_version)

    Then "the stale config is not mistaken for this project's declaration"
    result == nil

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "declared_ruby_version is nil when there is no deps manifest (Homebrew fallback)" do
    Given "a project with no dependencies.rb"
    root = Pathname.new(Dir.mktmpdir("runner-ruby-fallback-"))
    Dev.stubs(:target_project_root).returns(root)
    runner = build_runner

    When "we read the declared ruby version"
    result = runner.send(:declared_ruby_version)

    Then "nothing is declared, so resolve_ruby_version will fall back to Homebrew Ruby"
    result == nil

    Cleanup
    FileUtils.rm_rf(root)
  end

  private

  # Extra keyword args are forwarded to Dev::Runner.new, so tests inject
  # fakes through the constructor seams instead of any_instance stubs.
  def build_runner(name: "testproject", commands: {}, build: nil, runner: nil, ruby: nil, **collaborators)
    yaml = { "name" => name, "commands" => commands }
    yaml["ruby"] = ruby if ruby
    yaml["build"] = build if build
    yaml["runner"] = runner if runner
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(YAML.dump(yaml))
    tmp.flush

    Dev::Runner.new(
      dev_yaml_path: Pathname.new(tmp.path),
      cfg_parser: Dev::ConfigParser.new(command_parser: Dev::CommandParser.new),
      **collaborators,
    )
  end

  # A hook installer whose ensure_installed is a benign no-op, for tests where
  # the `up` flow runs but the shell RC must never be touched.
  def stubbed_hook_installer
    hook_installer = typed_mock(Dev::Cd::HookInstaller)
    hook_installer.stubs(:ensure_installed).returns(:already_present)
    hook_installer
  end

  # An in-sync staleness fake: no warnings, and stamping is a no-op — keeps
  # `up`/`install-deps` tests from writing the real ~/.dev/state stamp.
  def fake_staleness
    staleness = typed_mock(Dev::Deps::Staleness)
    staleness.stubs(:messages).returns([])
    staleness.stubs(:stamp_installed!)
    staleness
  end

  def fake_ui
    ui = typed_mock(Dev::Cli::Ui)
    ui.stubs(:print_header)
    ui
  end
end

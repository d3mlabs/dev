# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev"
require "dev/runner"
require "dev/credentials"
require "dev/deps/cmake_integration"
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

  test "up ensures the dev cd shell hook (idempotently)" do
    Given "a Runner with no project up command and a hook installer expectation"
    runner = build_runner(commands: {})
    runner.stubs(:install_locked_deps)
    Dev::Cd::HookInstaller.any_instance.expects(:ensure_installed).once.returns(:already_present)

    When "we run up"
    runner.run(["up"], ui: fake_ui)

    Then "the expectation on the hook installer holds"
    true
  end

  test "a project up command overrides the builtin: install runs first, then the script" do
    Given "a Runner whose dev.yml defines up and a spy on both stages"
    runner = build_runner(commands: { "up" => { "run" => "./bin/up.rb", "desc" => "Setup", "container" => false } })
    Dev::Cd::HookInstaller.any_instance.stubs(:ensure_installed).returns(:already_present)
    execution_order = []
    runner.stubs(:install_locked_deps).with { execution_order << :builtin_install; true }
    Dev::ShellCommand.any_instance.stubs(:execute).with { execution_order << :project_script; true }

    When "we run up"
    runner.run(["up"], ui: fake_ui)

    Then "OverriddenCommand super()-dispatches the builtin before the project script"
    execution_order == [:builtin_install, :project_script]
  end

  test "up resolves docker build arg credentials before executing" do
    Given "a Runner with build container build_args and an up command"
    runner = build_runner(
      commands: { "up" => { "run" => "./bin/up.rb", "desc" => "Setup", "container" => false } },
      build: { "container" => {
        "image" => "myapp-linux", "registry" => "myregistry",
        "build_args" => { "WWISE_EMAIL" => "wwise/email" },
      } },
    )
    Dev::ShellCommand.any_instance.stubs(:execute)
    runner.stubs(:install_locked_deps)
    Dev::Cd::HookInstaller.any_instance.stubs(:ensure_installed).returns(:already_present)

    When "we run up"
    runner.run(["up"], ui: fake_ui)

    Then "build args are resolved (prompting and storing on first run)"
    1 * Dev::Credentials.resolve_build_args({ "WWISE_EMAIL" => "wwise/email" })
  end

  test "up without build container skips credential provisioning" do
    Given "a Runner without a build container"
    runner = build_runner(commands: { "up" => { "run" => "./bin/up.rb", "desc" => "Setup" } })
    Dev::ShellCommand.any_instance.stubs(:execute)
    runner.stubs(:install_locked_deps)
    Dev::Cd::HookInstaller.any_instance.stubs(:ensure_installed).returns(:already_present)

    When "we run up"
    runner.run(["up"], ui: fake_ui)

    Then "credentials are never resolved"
    0 * Dev::Credentials.resolve_build_args(anything)
  end

  test "non-up commands do not provision credentials eagerly" do
    Given "a Runner with build container build_args and a test command"
    runner = build_runner(
      commands: { "test" => { "run" => "./bin/test.sh", "desc" => "Run tests", "container" => false } },
      build: { "container" => {
        "image" => "myapp-linux", "registry" => "myregistry",
        "build_args" => { "WWISE_EMAIL" => "wwise/email" },
      } },
    )
    Dev::ShellCommand.any_instance.stubs(:execute)

    When "we run a non-up command"
    runner.run(["test"], ui: fake_ui)

    Then "credentials are not resolved eagerly"
    0 * Dev::Credentials.resolve_build_args(anything)
  end

  test "declared_ruby_version prefers the dependencies.rb ruby directive over dev.yml" do
    Given "a project whose dependencies.rb declares ruby and whose dev.yml also pins one"
    root = Pathname.new(Dir.mktmpdir("runner-ruby-deps-"))
    File.write(root / "dependencies.rb", <<~RUBY)
      require "dev/deps"
      Dev::Deps.define { ruby "9.9.9" }
    RUBY
    Dev.stubs(:target_project_root).returns(root)
    runner = build_runner

    When "we read the declared ruby version"
    result = runner.send(:declared_ruby_version)

    Then "the first-class dependencies.rb directive wins"
    result == "9.9.9"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "declared_ruby_version falls back to dev.yml ruby when there is no deps manifest" do
    Given "a project with no dependencies.rb (e.g. dev's own repo)"
    root = Pathname.new(Dir.mktmpdir("runner-ruby-fallback-"))
    Dev.stubs(:target_project_root).returns(root)
    runner = build_runner

    When "we read the declared ruby version"
    result = runner.send(:declared_ruby_version)

    Then "it falls back to the dev.yml ruby:"
    result == "4.0.1"

    Cleanup
    FileUtils.rm_rf(root)
  end

  private

  def build_runner(name: "testproject", commands: {}, build: nil, runner: nil)
    yaml = { "name" => name, "ruby" => "4.0.1", "commands" => commands }
    yaml["build"] = build if build
    yaml["runner"] = runner if runner
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(YAML.dump(yaml))
    tmp.flush

    Dev::Runner.new(
      dev_yaml_path: Pathname.new(tmp.path),
      cfg_parser: Dev::ConfigParser.new(command_parser: Dev::CommandParser.new),
    )
  end

  def fake_ui
    ui = typed_mock(Dev::Cli::Ui)
    ui.stubs(:print_header)
    ui
  end
end

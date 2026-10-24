# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/install_deps_command"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::InstallDepsCommandTest < Minitest::Test
  include SorbetHelper

  test "traits: staleness-exempt (it IS the remediation) and stamps on success" do
    Given "the builtin"
    command = build_command

    Expect "the declarative traits"
    command.staleness_exempt? == true
    command.stamps? == true
    !command.hidden?
  end

  test "call installs for the detected env/host, then runs both hygiene hooks scoped to the project" do
    Given "a command with every collaborator faked, over a project that locks gems"
    root = Pathname.new(Dir.mktmpdir("install-deps-"))
    lock(root, gem_dep, brew_build_dep)
    installer = typed_mock(Dev::Deps::Installer)
    installer.expects(:install)
      .with(env: Dev::Deps.detect_env, host: Dev::Deps.detect_host, groups: nil, except: [], integration_types: nil)
      .once
    host_service = typed_mock(Dev::HostService)
    host_service.expects(:sync_skills).with(project_root: root).once
    host_service.expects(:sync_learnings).with(project_root: root).once
    command = Dev::Builtins::InstallDepsCommand.new(
      installer_factory: ->(_lockfile, _integrations) { installer },
      host_service: host_service,
    )

    When "running dev deps install"
    command.call(args: no_args, context: build_context(root))

    Then "the hooks received the project in hand"
    true

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "--group narrows the install to the named groups" do
    Given "a project locking a build-group brew dep and an app-group gem"
    root = Pathname.new(Dir.mktmpdir("install-deps-group-"))
    lock(root, gem_dep, brew_build_dep)
    installer = typed_mock(Dev::Deps::Installer)
    command = build_command(installer:)

    When "running dev deps install --group build"
    command.call(args: parsed_args(command, ["--group", "build"]), context: build_context(root))

    Then "the installer received the narrowed selection"
    1 * installer.install(
      env: Dev::Deps.detect_env, host: Dev::Deps.detect_host, groups: [:build], except: [], integration_types: nil
    )

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "--group=value is read like --group value" do
    Given "a project locking an app-group gem"
    root = Pathname.new(Dir.mktmpdir("install-deps-group-gems-"))
    lock(root, gem_dep, brew_build_dep)
    installer = typed_mock(Dev::Deps::Installer)
    command = build_command(installer:)

    When "running dev deps install --group=app"
    command.call(args: parsed_args(command, ["--group=app"]), context: build_context(root))

    Then "the app group installed"
    1 * installer.install(
      env: Dev::Deps.detect_env, host: Dev::Deps.detect_host, groups: [:app], except: [], integration_types: nil
    )

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "--integration keeps only the named integrations — the image bootstrap's brew-only build install" do
    Given "a build group mixing a brew toolchain with a host-installed gh artifact"
    root = Pathname.new(Dir.mktmpdir("install-deps-integration-"))
    lock(root, gem_dep, brew_build_dep, gh_build_dep)
    installer = typed_mock(Dev::Deps::Installer)
    command = build_command(installer:)

    When "running dev deps install --group build --integration brew"
    command.call(args: parsed_args(command, ["--group", "build", "--integration", "brew"]), context: build_context(root))

    Then "the installer received both narrowings"
    1 * installer.install(
      env: Dev::Deps.detect_env, host: Dev::Deps.detect_host,
      groups: [:build], except: [], integration_types: [:brew]
    )

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "--except drops the named groups from the install" do
    Given "a project locking a build-group brew dep and an app-group gem"
    root = Pathname.new(Dir.mktmpdir("install-deps-except-"))
    lock(root, gem_dep, brew_build_dep)
    installer = typed_mock(Dev::Deps::Installer)
    command = build_command(installer:)

    When "running dev deps install --except app"
    command.call(args: parsed_args(command, ["--except", "app"]), context: build_context(root))

    Then "the installer received the exclusion"
    1 * installer.install(
      env: Dev::Deps.detect_env, host: Dev::Deps.detect_host, groups: nil, except: [:app], integration_types: nil
    )

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "inside the container, the install excludes nothing by default (the container owns its data root, ADR-0008)" do
    Given "an inside command over a project locking a build-group brew dep and an app-group gem"
    root = Pathname.new(Dir.mktmpdir("install-deps-inside-"))
    lock(root, gem_dep, brew_build_dep)
    installer = typed_mock(Dev::Deps::Installer)
    command = build_command(installer:, inside_container: true)

    When "running dev deps install with no flags"
    command.call(args: no_args, context: build_context(root))

    Then "the whole lock is installed, same as on a host — the locked Ruby included, as a brew pin from Linuxbrew"
    1 * installer.install(
      env: Dev::Deps.detect_env, host: Dev::Deps.detect_host, groups: nil, except: [], integration_types: nil
    )

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "inside the container, an explicit --except is honoured as given" do
    Given "an inside command"
    root = Pathname.new(Dir.mktmpdir("install-deps-inside-except-"))
    lock(root, gem_dep, brew_build_dep)
    installer = typed_mock(Dev::Deps::Installer)
    command = build_command(installer:, inside_container: true)

    When "running dev deps install --except app"
    command.call(args: parsed_args(command, ["--except", "app"]), context: build_context(root))

    Then "the user's exclusion is the whole exclusion, and with no gems selected no Ruby is provisioned"
    1 * installer.install(
      env: Dev::Deps.detect_env, host: Dev::Deps.detect_host, groups: nil, except: [:app], integration_types: nil
    )

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "inside the container, the installer gets the same integration set as a host and only the host hygiene hooks stay off" do
    Given "an inside command whose factory records its inputs"
    root = Pathname.new(Dir.mktmpdir("install-deps-inside-wiring-"))
    installer = typed_mock(Dev::Deps::Installer)
    installer.stubs(:install)
    factory_inputs = []
    host_service = typed_mock(Dev::HostService)
    command = Dev::Builtins::InstallDepsCommand.new(
      installer_factory: ->(lockfile, integrations) {
        factory_inputs << [lockfile, integrations]
        installer
      },
      host_service: host_service,
      inside_container: true,
    )

    When "running dev deps install"
    command.call(args: no_args, context: build_context(root))

    Then "every installing type is wired inside — the container is a host with its own data root — and the host-side hooks do not run"
    _, integrations = factory_inputs.fetch(0)
    integrations.keys.sort == Dev::Deps::Registry.host_integrations(project_root: root, store: Dev::Deps::LocalStore.new(data_root: root.to_s)).keys.sort
    integrations.key?(:bundler)
    integrations.key?(:brew)
    integrations.key?(:cmake)
    integrations.key?(:gh)
    0 * host_service.sync_skills
    0 * host_service.sync_learnings

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "--pinned-taps puts the brew integration in pinned mode and is not mistaken for a group or integration" do
    Given "a factory that records its integrations and an installer that records its narrowing"
    root = Pathname.new(Dir.mktmpdir("install-deps-pinned-"))
    installer = typed_mock(Dev::Deps::Installer)
    factory_inputs = []
    command = Dev::Builtins::InstallDepsCommand.new(
      installer_factory: ->(lockfile, integrations) {
        factory_inputs << [lockfile, integrations]
        installer
      },
      host_service: quiet_host_service,
    )

    When "running dev deps install --group build --integration brew --pinned-taps"
    command.call(args: parsed_args(command, %w[--group build --integration brew --pinned-taps]), context: build_context(root))

    Then "brew pins taps; the group and integration narrowing are what was named"
    _, integrations = factory_inputs.fetch(0)
    integrations.fetch(:brew).pin_taps?
    1 * installer.install(env: anything, host: anything, groups: [:build], except: [], integration_types: [:brew])

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "call builds the installer over the project's lockfile and host integrations" do
    Given "a factory that records its inputs"
    root = Pathname.new(Dir.mktmpdir("install-deps-wiring-"))
    installer = typed_mock(Dev::Deps::Installer)
    installer.stubs(:install)
    factory_inputs = []
    command = Dev::Builtins::InstallDepsCommand.new(
      installer_factory: ->(lockfile, integrations) {
        factory_inputs << [lockfile, integrations]
        installer
      },
      host_service: quiet_host_service,
    )

    When "running dev deps install"
    command.call(args: no_args, context: build_context(root))

    Then "the installer got the project-rooted lockfile and the host integration set"
    lockfile, integrations = factory_inputs.fetch(0)
    lockfile.is_a?(Dev::Deps::Lockfile)
    integrations.key?(:bundler)
    integrations.key?(:brew)

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "the default factory builds the real installer" do
    Given "a command with the default factory over an empty project"
    # The empty project keeps the real collaborators inert: the lockfile
    # pins nothing (install dispatches nothing). Only the machine-global
    # boundary — the host service — is faked.
    root = Pathname.new(Dir.mktmpdir("install-deps-default-"))
    command = Dev::Builtins::InstallDepsCommand.new(host_service: quiet_host_service)

    When "running dev deps install"
    command.call(args: no_args, context: build_context(root))

    Then "the real install pass leaves the empty project untouched"
    Dir.children(root).empty?

    Cleanup
    FileUtils.rm_rf(root)
  end

  private

  def build_command(installer: typed_mock(Dev::Deps::Installer), inside_container: false)
    Dev::Builtins::InstallDepsCommand.new(
      installer_factory: ->(_lockfile, _integrations) { installer },
      host_service: quiet_host_service,
      inside_container:,
    )
  end

  # Writes a real deps.lock under the project root —
  # the lockfile is a file contract, not a boundary to fake.
  def lock(root, *deps)
    Dev::Deps::Lockfile.new(dir: root).lock(deps)
  end

  def gem_dep
    Dev::Deps::Dependency.new(name: "rake", integration: :bundler, group: :app,
      version: "13.0.0", hash: nil, metadata: {})
  end

  def brew_build_dep
    Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build,
      version: "4.4.3", hash: nil, metadata: {})
  end

  def gh_build_dep
    Dev::Deps::Dependency.new(name: "UnrealEngine", integration: :gh, group: :build,
      version: "5.6.1-css-83", hash: nil, metadata: { "repo" => "satisfactorymodding/UnrealEngine" })
  end

  def quiet_host_service
    host_service = typed_mock(Dev::HostService)
    host_service.stubs(:sync_skills)
    host_service.stubs(:sync_learnings)
    host_service
  end

  def build_context(project_root)
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui),
      project: Dev::ProjectContext.new(name: "TestProject", root: project_root),
    )
  end
end

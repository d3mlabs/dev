# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/builtins/install_deps_command"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Cli::Builtins::InstallDepsCommandTest < Minitest::Test
  include SorbetHelper

  test "traits: staleness-exempt (it IS the remediation) and stamps on success" do
    Given "the builtin"
    command = build_command

    Expect "the declarative traits"
    command.staleness_exempt? == true
    command.stamps? == true
    !command.hidden?
  end

  test "call trusts the project's shadowenv for this user before any integration runs — trust is the user's, not the files'" do
    Given "a command whose trust collaborator and installer are both expecting, in order"
    root = Pathname.new(Dir.mktmpdir("install-deps-trust-"))
    lock(root, gem_dep)
    order = sequence("trust before install")
    trust = typed_mock(Dev::ShadowenvTrust)
    installer = typed_mock(Dev::Deps::Installer)
    host_service = typed_mock(Dev::HostService)
    # call order: the integrations spawn under the project's shadowenv, which refuses a directory this user has not yet trusted
    trust.expects(:ensure!).with(project_root: root).once.in_sequence(order)
    installer.expects(:install).once.in_sequence(order)
    command = build_command(installer:, host_service:, trust:)

    When "running dev deps install"
    command.call(args: no_args, context: build_context(root))

    Then "the sequence held"
    _ * host_service.sync_skills
    _ * host_service.sync_learnings

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "call installs for the detected env/host, then runs both hygiene hooks scoped to the project" do
    Given "a command with every collaborator faked, over a project that locks gems"
    root = Pathname.new(Dir.mktmpdir("install-deps-"))
    lock(root, gem_dep, brew_build_dep)
    installer = typed_mock(Dev::Deps::Installer)
    host_service = typed_mock(Dev::HostService)
    trust = typed_mock(Dev::ShadowenvTrust)
    command = build_command(installer:, host_service:, trust:)

    When "running dev deps install"
    command.call(args: no_args, context: build_context(root))

    Then "the hooks received the project in hand"
    _ * trust.ensure! >> true
    1 * installer.install(
      env: Dev::Deps.detect_env, host: Dev::Deps.detect_host, groups: nil, except: [], integration_types: nil
    )
    1 * host_service.sync_skills(project_root: root)
    1 * host_service.sync_learnings(project_root: root)

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "--group narrows the install to the named groups" do
    Given "a project locking a build-group brew dep and an app-group gem"
    root = Pathname.new(Dir.mktmpdir("install-deps-group-"))
    lock(root, gem_dep, brew_build_dep)
    installer = typed_mock(Dev::Deps::Installer)
    host_service = typed_mock(Dev::HostService)
    trust = typed_mock(Dev::ShadowenvTrust)
    command = build_command(installer:, host_service:, trust:)

    When "running dev deps install --group build"
    command.call(args: parsed_args(command, ["--group", "build"]), context: build_context(root))

    Then "the installer received the narrowed selection"
    _ * trust.ensure! >> true
    _ * host_service.sync_skills
    _ * host_service.sync_learnings
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
    host_service = typed_mock(Dev::HostService)
    trust = typed_mock(Dev::ShadowenvTrust)
    command = build_command(installer:, host_service:, trust:)

    When "running dev deps install --group=app"
    command.call(args: parsed_args(command, ["--group=app"]), context: build_context(root))

    Then "the app group installed"
    _ * trust.ensure! >> true
    _ * host_service.sync_skills
    _ * host_service.sync_learnings
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
    host_service = typed_mock(Dev::HostService)
    trust = typed_mock(Dev::ShadowenvTrust)
    command = build_command(installer:, host_service:, trust:)

    When "running dev deps install --group build --integration brew"
    command.call(args: parsed_args(command, ["--group", "build", "--integration", "brew"]), context: build_context(root))

    Then "the installer received both narrowings"
    _ * trust.ensure! >> true
    _ * host_service.sync_skills
    _ * host_service.sync_learnings
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
    host_service = typed_mock(Dev::HostService)
    trust = typed_mock(Dev::ShadowenvTrust)
    command = build_command(installer:, host_service:, trust:)

    When "running dev deps install --except app"
    command.call(args: parsed_args(command, ["--except", "app"]), context: build_context(root))

    Then "the installer received the exclusion"
    _ * trust.ensure! >> true
    _ * host_service.sync_skills
    _ * host_service.sync_learnings
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
    trust = typed_mock(Dev::ShadowenvTrust)
    command = build_command(installer:, host_service: typed_mock(Dev::HostService), trust:, inside_container: true)

    When "running dev deps install with no flags"
    command.call(args: no_args, context: build_context(root))

    Then "the whole lock is installed, same as on a host — the locked Ruby included, as a brew pin from Linuxbrew"
    _ * trust.ensure! >> true
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
    trust = typed_mock(Dev::ShadowenvTrust)
    command = build_command(installer:, host_service: typed_mock(Dev::HostService), trust:, inside_container: true)

    When "running dev deps install --except app"
    command.call(args: parsed_args(command, ["--except", "app"]), context: build_context(root))

    Then "the user's exclusion is the whole exclusion, and with no gems selected no Ruby is provisioned"
    _ * trust.ensure! >> true
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
    factory_inputs = []
    host_service = typed_mock(Dev::HostService)
    trust = typed_mock(Dev::ShadowenvTrust)
    command = Dev::Cli::Builtins::InstallDepsCommand.new(
      installer_factory: ->(lockfile, integrations, ui) {
        factory_inputs << [lockfile, integrations, ui]
        installer
      },
      host_service: host_service,
      shadowenv_trust: trust,
      inside_container: true,
    )

    When "running dev deps install"
    command.call(args: no_args, context: build_context(root))

    Then "every installing type is wired inside — the container is a host with its own data root — and the host-side hooks do not run"
    _ * trust.ensure! >> true
    _ * installer.install
    _, integrations, _ = factory_inputs.fetch(0)
    integrations.keys.sort == Dev::Deps::Registry.host_integrations(
      project_root: root, project_name: "TestProject", store: Dev::Deps::LocalStore.new(data_root: root.to_s), ui: Dev::NoUi.new,
    ).keys.sort
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
    host_service = typed_mock(Dev::HostService)
    trust = typed_mock(Dev::ShadowenvTrust)
    command = Dev::Cli::Builtins::InstallDepsCommand.new(
      installer_factory: ->(lockfile, integrations, ui) {
        factory_inputs << [lockfile, integrations, ui]
        installer
      },
      host_service: host_service,
      shadowenv_trust: trust,
    )

    When "running dev deps install --group build --integration brew --pinned-taps"
    command.call(args: parsed_args(command, %w[--group build --integration brew --pinned-taps]), context: build_context(root))

    Then "brew pins taps; the group and integration narrowing are what was named"
    _ * trust.ensure! >> true
    _ * host_service.sync_skills
    _ * host_service.sync_learnings
    _, integrations, _ = factory_inputs.fetch(0)
    integrations.fetch(:brew).pin_taps?
    1 * installer.install(env: anything, host: anything, groups: [:build], except: [], integration_types: [:brew])

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "call builds the installer over the project's lockfile, the host integrations and the context's Ui (dev#573)" do
    Given "a factory that records its inputs"
    root = Pathname.new(Dir.mktmpdir("install-deps-wiring-"))
    installer = typed_mock(Dev::Deps::Installer)
    factory_inputs = []
    host_service = typed_mock(Dev::HostService)
    trust = typed_mock(Dev::ShadowenvTrust)
    command = Dev::Cli::Builtins::InstallDepsCommand.new(
      installer_factory: ->(lockfile, integrations, ui) {
        factory_inputs << [lockfile, integrations, ui]
        installer
      },
      host_service: host_service,
      shadowenv_trust: trust,
    )
    context = build_context(root)

    When "running dev deps install"
    command.call(args: no_args, context: context)

    Then "the installer got the project-rooted lockfile, the host integration set and the Ui the run speaks through"
    _ * trust.ensure! >> true
    _ * installer.install
    _ * host_service.sync_skills
    _ * host_service.sync_learnings
    lockfile, integrations, ui = factory_inputs.fetch(0)
    lockfile.is_a?(Dev::Deps::Lockfile)
    integrations.key?(:bundler)
    integrations.key?(:brew)
    ui.equal?(context.ui)

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "the default factory builds the real installer" do
    Given "a command with the default factory over an empty project"
    # The empty project keeps the real collaborators inert: the lockfile
    # pins nothing (install dispatches nothing). Only the machine-global
    # boundary — the host service — is faked.
    root = Pathname.new(Dir.mktmpdir("install-deps-default-"))
    host_service = typed_mock(Dev::HostService)
    command = Dev::Cli::Builtins::InstallDepsCommand.new(host_service: host_service)

    When "running dev deps install"
    command.call(args: no_args, context: build_context(root))

    Then "the real install pass writes nothing but the project's own (trusted, empty) .shadowenv.d"
    _ * host_service.sync_skills
    _ * host_service.sync_learnings
    Dir.children(root) == [".shadowenv.d"]
    Dir.children(root / ".shadowenv.d").none? { |entry| entry.end_with?(".lisp") }

    Cleanup
    FileUtils.rm_rf(root)
  end

  private

  # The trust and host service are collaborators the command calls; their
  # own tests own the real behaviour, so each test states their answers.
  def build_command(
    installer: typed_mock(Dev::Deps::Installer), host_service: typed_mock(Dev::HostService),
    trust: typed_mock(Dev::ShadowenvTrust), inside_container: false
  )
    Dev::Cli::Builtins::InstallDepsCommand.new(
      installer_factory: ->(_lockfile, _integrations, _ui) { installer },
      host_service: host_service,
      shadowenv_trust: trust,
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

  def build_context(project_root)
    Dev::Cli::ExecutionContext.new(
      ui: typed_mock(Dev::Ui),
      project: Dev::Cli::ProjectContext.new(name: "TestProject", root: project_root),
    )
  end
end

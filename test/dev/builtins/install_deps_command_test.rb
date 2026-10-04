# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/install_deps_command"
require "fileutils"
require "pathname"
require "dev/shadowenv_ruby"
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

  test "call provisions the pinned Ruby, installs for the detected env/host, then runs both hygiene hooks" do
    Given "a command with every collaborator faked, over a project that locks gems"
    root = Pathname.new(Dir.mktmpdir("install-deps-"))
    lock(root, gem_dep, brew_build_dep)
    installer = typed_mock(Dev::Deps::Installer)
    installer.expects(:install)
      .with(env: Dev::Deps.detect_env, host: Dev::Deps.detect_host, groups: nil, except: [], integration_types: nil)
      .once
    linker = typed_mock(Dev::Deps::GemSkillLinker)
    linker.expects(:link_all).once
    host_service = typed_mock(Dev::HostService)
    host_service.expects(:sync_learnings).with(project_root: root).once
    linker_roots = []
    command = Dev::Builtins::InstallDepsCommand.new(
      installer_factory: ->(_lockfile, _integrations) { installer },
      gem_skill_linker_factory: ->(project_root) {
        linker_roots << project_root
        linker
      },
      host_service: host_service,
    )
    # Headless boxes reach dev deps install before any CommandRunner provisioning,
    # so the builtin provisions the toolchain itself — the true boundary.
    Dev::ShadowenvRuby.expects(:converge!).with(ruby_version: "4.0.1", project_root: root).once

    When "running dev deps install"
    command.call(args: [], context: build_context(root))

    Then "the linker was scoped to the project in hand"
    linker_roots == [root]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "--group narrows the install to the named groups and skips the project Ruby when no gems are selected" do
    Given "a project locking a build-group brew dep and an app-group gem"
    root = Pathname.new(Dir.mktmpdir("install-deps-group-"))
    lock(root, gem_dep, brew_build_dep)
    installer = typed_mock(Dev::Deps::Installer)
    command = build_command(installer:)
    # The image bootstrap runs this on Homebrew's Ruby: provisioning the
    # project's pinned Ruby there would be waste nobody consumes.
    Dev::ShadowenvRuby.expects(:converge!).never

    When "running dev deps install --group build"
    command.call(args: ["--group", "build"], context: build_context(root))

    Then "the installer received the narrowed selection"
    1 * installer.install(
      env: Dev::Deps.detect_env, host: Dev::Deps.detect_host, groups: [:build], except: [], integration_types: nil
    )

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "--group still provisions the project Ruby when the selection locks gems" do
    Given "a project locking an app-group gem"
    root = Pathname.new(Dir.mktmpdir("install-deps-group-gems-"))
    lock(root, gem_dep, brew_build_dep)
    installer = typed_mock(Dev::Deps::Installer)
    command = build_command(installer:)
    Dev::ShadowenvRuby.expects(:converge!).with(ruby_version: "4.0.1", project_root: root).once

    When "running dev deps install --group=app"
    command.call(args: ["--group=app"], context: build_context(root))

    Then "the pinned Ruby converged (bundler installs against it) and the app group installed"
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
    Dev::ShadowenvRuby.expects(:converge!).never

    When "running dev deps install --group build --integration brew"
    command.call(args: ["--group", "build", "--integration", "brew"], context: build_context(root))

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
    Dev::ShadowenvRuby.expects(:converge!).never

    When "running dev deps install --except app"
    command.call(args: ["--except", "app"], context: build_context(root))

    Then "the installer received the exclusion; the gem-less selection provisioned no Ruby"
    1 * installer.install(
      env: Dev::Deps.detect_env, host: Dev::Deps.detect_host, groups: nil, except: [:app], integration_types: nil
    )

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "inside the container, the install defaults to --except build: the image already carries that group" do
    Given "an inside command over a project locking a build-group brew dep and an app-group gem"
    root = Pathname.new(Dir.mktmpdir("install-deps-inside-"))
    lock(root, gem_dep, brew_build_dep)
    installer = typed_mock(Dev::Deps::Installer)
    command = build_command(installer:, inside_container: true)
    Dev::ShadowenvRuby.stubs(:converge!)

    When "running dev deps install with no flags"
    command.call(args: [], context: build_context(root))

    Then "the build group is excluded by default"
    1 * installer.install(
      env: Dev::Deps.detect_env, host: Dev::Deps.detect_host, groups: nil, except: [:build], integration_types: nil
    )

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "inside the container, an explicit --except replaces the build default rather than adding to it" do
    Given "an inside command"
    root = Pathname.new(Dir.mktmpdir("install-deps-inside-except-"))
    lock(root, gem_dep, brew_build_dep)
    installer = typed_mock(Dev::Deps::Installer)
    command = build_command(installer:, inside_container: true)
    Dev::ShadowenvRuby.expects(:converge!).never

    When "running dev deps install --except app"
    command.call(args: ["--except", "app"], context: build_context(root))

    Then "the user's exclusion is the whole exclusion"
    1 * installer.install(
      env: Dev::Deps.detect_env, host: Dev::Deps.detect_host, groups: nil, except: [:app], integration_types: nil
    )

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
      gem_skill_linker_factory: ->(_project_root) {
        linker = typed_mock(Dev::Deps::GemSkillLinker)
        linker.stubs(:link_all)
        linker
      },
      host_service: quiet_host_service,
    )
    Dev::ShadowenvRuby.stubs(:converge!)

    When "running dev deps install"
    command.call(args: [], context: build_context(root))

    Then "the installer got the project-rooted lockfile and the host integration set"
    lockfile, integrations = factory_inputs.fetch(0)
    lockfile.is_a?(Dev::Deps::Lockfile)
    integrations.key?(:bundler)
    integrations.key?(:brew)

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "the default factories build the real installer and skill linker" do
    Given "a command with default factories over an empty project"
    # The empty project keeps the real collaborators inert: the lockfile
    # pins nothing (install dispatches nothing) and no Gemfile exists (the
    # linker returns before shelling out). Only the machine-global
    # boundaries — the Ruby provisioner and the host service — are faked.
    root = Pathname.new(Dir.mktmpdir("install-deps-default-"))
    command = Dev::Builtins::InstallDepsCommand.new(host_service: quiet_host_service)
    Dev::ShadowenvRuby.stubs(:converge!)

    When "running dev deps install"
    command.call(args: [], context: build_context(root))

    Then "the real install pass leaves the empty project untouched"
    Dir.children(root).empty?

    Cleanup
    FileUtils.rm_rf(root)
  end

  private

  def build_command(installer: typed_mock(Dev::Deps::Installer), inside_container: false)
    Dev::Builtins::InstallDepsCommand.new(
      installer_factory: ->(_lockfile, _integrations) { installer },
      gem_skill_linker_factory: ->(_project_root) {
        linker = typed_mock(Dev::Deps::GemSkillLinker)
        linker.stubs(:link_all)
        linker
      },
      host_service: quiet_host_service,
      inside_container:,
    )
  end

  # Writes a real deps.lock/build-deps.lock pair under the project root —
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
    host_service.stubs(:sync_learnings)
    host_service
  end

  def build_context(project_root)
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui),
      project: Dev::ProjectContext.new(name: "TestProject", root: project_root, ruby_version: "4.0.1"),
    )
  end
end

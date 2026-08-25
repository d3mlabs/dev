# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/install_deps_command"
require "fileutils"
require "pathname"
require "shadowenv_ruby"
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
    Given "a command with every collaborator faked"
    root = Pathname.new(Dir.mktmpdir("install-deps-"))
    installer = typed_mock(Dev::Deps::DependencyInstaller)
    installer.expects(:install).with(env: Dev::Deps.detect_env, host: Dev::Deps.detect_host).once
    linker = typed_mock(Dev::Deps::GemSkillLinker)
    linker.expects(:link_all).once
    synchronizer = mock
    synchronizer.expects(:sync).with(project_root: root).once
    linker_roots = []
    command = Dev::Builtins::InstallDepsCommand.new(
      installer_factory: ->(_lockfile, _integrations) { installer },
      gem_skill_linker_factory: ->(project_root) {
        linker_roots << project_root
        linker
      },
      synchronizer: synchronizer,
    )
    # Headless boxes reach install-deps before any CommandRunner provisioning,
    # so the builtin provisions the toolchain itself — the true boundary.
    ShadowenvRuby.expects(:ensure!).with(ruby_version: "4.0.1", project_root: root).once

    When "running install-deps"
    command.call(args: [], context: build_context(root))

    Then "the linker was scoped to the project in hand"
    linker_roots == [root]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "call builds the installer over the project's lockfile and host integrations" do
    Given "a factory that records its inputs"
    root = Pathname.new(Dir.mktmpdir("install-deps-wiring-"))
    installer = typed_mock(Dev::Deps::DependencyInstaller)
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
      synchronizer: stub(sync: nil),
    )
    ShadowenvRuby.stubs(:ensure!)

    When "running install-deps"
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
    # boundaries — the Ruby provisioner and the learnings synchronizer —
    # are faked.
    root = Pathname.new(Dir.mktmpdir("install-deps-default-"))
    command = Dev::Builtins::InstallDepsCommand.new(synchronizer: stub(sync: nil))
    ShadowenvRuby.stubs(:ensure!)

    When "running install-deps"
    command.call(args: [], context: build_context(root))

    Then "the real install pass leaves the empty project untouched"
    Dir.children(root).empty?

    Cleanup
    FileUtils.rm_rf(root)
  end

  private

  def build_command
    Dev::Builtins::InstallDepsCommand.new(
      installer_factory: ->(_lockfile, _integrations) { typed_mock(Dev::Deps::DependencyInstaller) },
      gem_skill_linker_factory: ->(_project_root) { typed_mock(Dev::Deps::GemSkillLinker) },
      synchronizer: stub(sync: nil),
    )
  end

  def build_context(project_root)
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui),
      project: Dev::ProjectContext.new(root: project_root, ruby_version: "4.0.1"),
    )
  end
end

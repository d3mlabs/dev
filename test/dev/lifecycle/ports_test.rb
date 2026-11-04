# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::PortsTest < Minitest::Test
  BUILDER = Dev::Lifecycle::BuilderSpec
  PACKAGER = Dev::Lifecycle::PackagerSpec

  test "a build: line becomes a ScriptBuilder at the project root; no builder is nil" do
    Given
    ports = Dev::Lifecycle::Ports.new(project_root: Pathname("/project"))
    scripted = Dev::Lifecycle::Target.new(name: "cellbound-3d", builder: BUILDER::Script.new(command: "./bin/build"))
    unbuilt = Dev::Lifecycle::Target.new(name: "rspock")

    Expect
    ports.builder_for(scripted).is_a?(Dev::Lifecycle::ScriptBuilder)
    ports.builder_for(scripted).command == "./bin/build"
    ports.builder_for(unbuilt).nil?
  end

  test "each packager declaration becomes its port: #{spec}" do
    Given
    ports = Dev::Lifecycle::Ports.new(project_root: Pathname("/project"))
    target = Dev::Lifecycle::Target.new(name: "rspock", packager: spec)

    Expect
    ports.packager_for(target).is_a?(port_class)
    ports.packager_for(target).to_s == rendered

    Where
    spec                                                                                                           | port_class                       | rendered
    Dev::Lifecycle::PackagerSpec::Archive.new                                                                      | Dev::Lifecycle::Archive          | "archive"
    Dev::Lifecycle::PackagerSpec::Archive.new(form: Dev::Lifecycle::Archive::Form::Tar.new)                        | Dev::Lifecycle::Archive          | "archive (tar)"
    Dev::Lifecycle::PackagerSpec::AsIs.new                                                                         | Dev::Lifecycle::AsIsPackager     | "as-is"
    Dev::Lifecycle::PackagerSpec::None.new                                                                         | Dev::Lifecycle::NonePackager     | "none"
    Dev::Lifecycle::PackagerSpec::Script.new(command: "./bin/package")                                             | Dev::Lifecycle::ScriptPackager   | "./bin/package"
  end

  test "the script ports run at the project root the Ports were built over, through its shell" do
    Given "a project whose scripts leave a trace, and a target declaring both"
    root = Pathname(Dir.mktmpdir("ports-"))
    project = root / "project"
    project.mkpath
    target = Dev::Lifecycle::Target.new(
      name: "cellbound-3d",
      builder: BUILDER::Script.new(command: 'echo built > "$DEV_INSTALL/built.txt"'),
      packager: PACKAGER::Script.new(command: 'cp "$DEV_INSTALL/built.txt" "$DEV_ARTIFACT.txt"'),
    )
    ports = Dev::Lifecycle::Ports.new(project_root: project)
    build = target.default_build
    install = root / "install"

    When
    ports.builder_for(target).build(build, install)
    packed = ports.packager_for(target).package(build, install, root / "store/cellbound-3d")

    Then
    packed.archive == root / "store/cellbound-3d.txt"
    packed.archive.read == "built\n"

    Cleanup
    FileUtils.rm_rf(root)
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "support/lifecycle_fixtures"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::ScriptBuilderTest < Minitest::Test
  include LifecycleFixtures

  test "the build: line runs at the project root with the build in its env and DEV_INSTALL created for it" do
    Given "a project whose build script records its env and stages a file"
    root = Pathname(Dir.mktmpdir("script-builder-"))
    project = root / "project"
    project.mkpath
    (project / "build.sh").write(<<~SH)
      #!/bin/sh
      set -eu
      pwd > env.txt
      echo "$DEV_TARGET $DEV_PLATFORM $DEV_CONFIG" >> env.txt
      echo "${DEV_ARTIFACT:-unset}" >> env.txt
      echo "staged" > "$DEV_INSTALL/game.txt"
    SH
    builder = Dev::Lifecycle::ScriptBuilder.new(command: "sh ./build.sh", project_root: project)
    install = root / "store/cellbound-3d-win64-dev/install"

    When
    builder.build(build("cellbound-3d-win64-dev"), install)

    Then
    (project / "env.txt").read.lines.map(&:chomp) == [project.realpath.to_s, "cellbound-3d win64 dev", "unset"]
    (install / "game.txt").read == "staged\n"
    builder.command == "sh ./build.sh"
    builder.to_s == "sh ./build.sh"
    builder.target_options_schema == []
    builder.name == "script"
    builder.version.nil?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a script that refuses the build (`*) exit 2`) fails loudly, naming the script, the build and the exit code" do
    Given
    root = Pathname(Dir.mktmpdir("script-builder-"))
    builder = Dev::Lifecycle::ScriptBuilder.new(command: "exit 2", project_root: root)

    When
    builder.build(build("cellbound-3d-server-linux64-dev"), root / "install")

    Then
    error = raises(Dev::Lifecycle::ScriptBuilder::BuildScriptFailedError)
    error.message == "build script `exit 2` for cellbound-3d-server-linux64-dev exited 2"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a project root that does not exist is a spawn error, not a script failure" do
    Given
    root = Pathname(Dir.mktmpdir("script-builder-"))
    builder = Dev::Lifecycle::ScriptBuilder.new(command: "true", project_root: root / "nonexistent")

    When
    builder.build(build("rspock"), root / "install")

    Then
    error = raises(Dev::Lifecycle::Shell::SpawnError)
    error.message.include?((root / "nonexistent").to_s)

    Cleanup
    FileUtils.rm_rf(root)
  end
end

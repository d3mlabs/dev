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

  test "the build: line runs at the project root with the build in its env and DEV_STAGE created for it; a script reading DEV_STAGE deprecates nothing" do
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
      echo "staged" > "$DEV_STAGE/game.txt"
    SH
    builder = Dev::Lifecycle::ScriptBuilder.new(command: "sh ./build.sh", project_root: project)
    stage = root / "store/cellbound-3d-win64-dev/stage"

    When
    builder.build(build("cellbound-3d-win64-dev"), stage)

    Then
    (project / "env.txt").read.lines.map(&:chomp) == [project.realpath.to_s, "cellbound-3d win64 dev", "unset"]
    (stage / "game.txt").read == "staged\n"
    builder.deprecations == []
    builder.command == "sh ./build.sh"
    builder.to_s == "sh ./build.sh"
    builder.target_options_schema == []
    builder.name == "script"
    builder.version.nil?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "the stage is fresh before the script runs: one that writes nothing leaves a previous build's files gone" do
    Given "a stage holding a previous build's files, and a script that stages nothing"
    root = Pathname(Dir.mktmpdir("script-builder-"))
    stage = root / "store/rspock/stage"
    (stage / "nested").mkpath
    (stage / "nested/old.txt").write("from the previous build")
    (stage / "old.gem").write("stale")
    builder = Dev::Lifecycle::ScriptBuilder.new(command: "true", project_root: root)

    When
    builder.build(build("rspock"), stage)

    Then
    stage.directory?
    stage.children == []

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a script that refuses the build (`*) exit 2`) fails loudly, naming the script, the build and the exit code" do
    Given
    root = Pathname(Dir.mktmpdir("script-builder-"))
    builder = Dev::Lifecycle::ScriptBuilder.new(command: "exit 2", project_root: root)

    When
    builder.build(build("cellbound-3d-server-linux64-dev"), root / "stage")

    Then
    error = raises(Dev::Lifecycle::ScriptBuilder::BuildScriptFailedError)
    error.message == "build script `exit 2` for cellbound-3d-server-linux64-dev exited 2"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a script written for $DEV_INSTALL still stages through the alias, and the builder reports the deprecation (dev#678)" do
    Given "a script file the builder: line names, reading the old key"
    root = Pathname(Dir.mktmpdir("script-builder-"))
    (root / "bin").mkpath
    (root / "bin/build").write("#!/bin/sh\nset -eu\necho staged > \"$DEV_INSTALL/game.txt\"\n")
    (root / "bin/build").chmod(0o755)
    builder = Dev::Lifecycle::ScriptBuilder.new(command: "./bin/build", project_root: root)
    stage = root / "store/cellbound-3d-win64-dev/stage"

    When
    builder.build(build("cellbound-3d-win64-dev"), stage)

    Then
    (stage / "game.txt").read == "staged\n"
    builder.deprecations == [
      "deprecated: the builder: script reads $DEV_INSTALL, one release's alias of $DEV_STAGE — " \
        "read $DEV_STAGE; the next dev release drops $DEV_INSTALL",
    ]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a project root that does not exist is a spawn error, not a script failure" do
    Given
    root = Pathname(Dir.mktmpdir("script-builder-"))
    builder = Dev::Lifecycle::ScriptBuilder.new(command: "true", project_root: root / "nonexistent")

    When
    builder.build(build("rspock"), root / "stage")

    Then
    error = raises(Dev::Lifecycle::Shell::SpawnError)
    error.message.include?((root / "nonexistent").to_s)

    Cleanup
    FileUtils.rm_rf(root)
  end
end

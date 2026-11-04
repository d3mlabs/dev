# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/command"
require "dev/command_parser"
require "dev/deps/dependency"
require "dev/deps/lockfile"
require "dev/environment_image"
require "dev/environment_ref"
require "dev/placement"
require "dev/placement_binder"
require "dev/project_images"
require "dev/target_parser"
require "fileutils"
require "pathname"
require "tmpdir"

# The composition root's binding step over a parsed dev.yml tree, its
# targets, and a real temp checkout's deps.lock.
transform!(RSpock::AST::Transformation)
class Dev::PlacementBinderTest < Minitest::Test
  def setup
    @root = Pathname(Dir.mktmpdir("placement-binder"))
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  test "every runnable node is bound, at any depth, and the tree's shape is kept" do
    Given "two pins and a tree with a group, a command with children, and leaves naming each shape"
    lock(image_pin("snappy-linux"), image_pin("snappy-server"))
    commands = parse(
      "build" => { "run" => "./bin/build.sh", "environment" => "snappy-linux" },
      "editor" => { "run" => "./bin/editor.sh", "environment" => "host", "hidden" => true },
      "test" => {
        "run" => "./bin/test.sh", "environment" => "snappy-linux", "desc" => "Run tests",
        "commands" => { "server" => { "run" => "./bin/test-server.sh", "environment" => "snappy-server" } },
      },
      "db" => { "desc" => "Database chores", "commands" => { "reset" => { "run" => "./bin/db-reset.sh", "environment" => "host" } } },
    )

    When
    bound = binder.bind(commands)

    Then "each command carries its placement; groups and children are where they were"
    bound.keys == ["build", "editor", "test", "db"]
    bound["build"].placement == Dev::Placement::Image.new(image: images.named("snappy-linux"))
    bound["editor"].placement == Dev::Placement::Host.new
    bound["editor"].hidden?
    bound["test"].placement.name == "snappy-linux"
    bound["test"].desc == "Run tests"
    bound["test"].children["server"].placement.name == "snappy-server"
    bound["db"].is_a?(Dev::CommandGroup)
    bound["db"].desc == "Database chores"
    bound["db"].children["reset"].placement == Dev::Placement::Host.new
    bound["build"].environment == Dev::EnvironmentRef::Image.new(name: "snappy-linux")
    commands["build"].placement.nil?
  end

  test "a command naming no environment takes the project's default: its one image" do
    Given
    lock(image_pin("snappy-linux"))
    commands = parse("build" => { "run" => "./bin/build.sh" })

    Expect
    binder.bind(commands)["build"].placement.name == "snappy-linux"
  end

  test "a name the lock does not pin fails at binding, under the command's path" do
    Given
    lock(image_pin("snappy-linux"), image_pin("snappy-server"))
    commands = parse("test" => { "run" => "./bin/test.sh", "environment" => "host",
                                 "commands" => { "editor" => { "run" => "./bin/editor.sh", "environment" => "snappy-srv" } } })

    When
    binder.bind(commands)

    Then
    error = raises(Dev::ProjectImages::UnknownImageError)
    error.message.include?("`test editor` runs in `snappy-srv`")
    error.message.include?("snappy-linux, snappy-server")
  end

  test "a command naming none among several pins fails at binding, under its path" do
    Given
    lock(image_pin("snappy-linux"), image_pin("snappy-server"))
    commands = parse("lint" => { "run" => "./bin/lint.sh" })

    When
    binder.bind(commands)

    Then
    error = raises(Dev::ProjectImages::AmbiguousEnvironmentImageError)
    error.message.include?("`lint` runs in a container but names no image")
    error.message.include?("add `environment: <name>`")
  end

  test "bind_targets binds each target's environment per platform and checks every image produces its platform (dev#192 K8)" do
    Given "a Linux image producing both desktop platforms, a server image producing none, and cellbound-3d's targets"
    lock(image_pin("cellbound-3d-linux", target_platforms: ["win64", "linux64"]), image_pin("cellbound-3d-server"))
    targets = parse_targets(
      "cellbound-3d-editor" => {
        "platforms" => ["linux64", "macos"], "environment" => { "linux64" => "cellbound-3d-linux", "macos" => "host" },
      },
      "cellbound-3d" => {
        "platforms" => ["win64", "linux64"], "configs" => ["dev", "release"], "environment" => "cellbound-3d-linux",
      },
      "payload" => { "environment" => "cellbound-3d-server" },
    )

    When
    bound = binder(host_os: "darwin").bind_targets(targets)

    Then "one placement per declared platform, under nil for the platform-less target, each already checked"
    bound.keys == ["cellbound-3d-editor", "cellbound-3d", "payload"]
    bound["cellbound-3d-editor"].placements == {
      Dev::Lifecycle::Platform::Linux64 => Dev::Placement::Image.new(image: images.named("cellbound-3d-linux")),
      Dev::Lifecycle::Platform::Macos => Dev::Placement::Host.new,
    }
    bound["cellbound-3d"].placements.keys == [Dev::Lifecycle::Platform::Win64, Dev::Lifecycle::Platform::Linux64]
    bound["cellbound-3d"].placements.values.all? { |placement| placement.name == "cellbound-3d-linux" }
    bound["payload"].placements == { nil => Dev::Placement::Image.new(image: images.named("cellbound-3d-server")) }
    bound["payload"].target == targets["payload"]
    bound["cellbound-3d"].host_platform == Dev::Lifecycle::Platform::Macos
  end

  test "a target naming no environment takes the project's default, which must still produce its platforms" do
    Given "snappy's shape: one image, targets name none"
    lock(image_pin("snappy-linux", target_platforms: ["win64", "linux64"]))
    targets = parse_targets("snappy-steam" => { "platforms" => ["win64"] }, "snappy-server" => { "platforms" => ["linux64"] })

    Expect
    binder.bind_targets(targets).transform_values { |bound| bound.placements.values.map(&:name) } ==
      { "snappy-steam" => ["snappy-linux"], "snappy-server" => ["snappy-linux"] }
  end

  test "a build pointed at an image that does not produce its platform fails at load, naming the fix" do
    Given "an image without msvc-wine asked for a win64 build"
    lock(image_pin("cellbound-3d-linux", target_platforms: ["linux64"]))
    targets = parse_targets(
      "cellbound-3d" => { "platforms" => ["linux64", "win64"], "configs" => ["dev"], "environment" => "cellbound-3d-linux" },
    )

    When
    binder.bind_targets(targets)

    Then
    error = raises(Dev::PlacementBinder::ImageDoesNotProduceError)
    error.message.include?("`cellbound-3d-win64` builds in cellbound-3d-linux, which does not produce win64")
    error.message.include?("add `target_platforms :win64` to its image block")
    error.message.include?("or name another environment")
  end

  test "an image declaring no target_platforms produces nothing, so no platform build may name it" do
    Given
    lock(image_pin("cellbound-3d-linux"))
    targets = parse_targets("cellbound-3d" => { "platforms" => ["linux64"], "environment" => "cellbound-3d-linux" })

    When
    binder.bind_targets(targets)

    Then
    raises Dev::PlacementBinder::ImageDoesNotProduceError
  end

  test "a host placement on a platform this machine is not binds: the host half is per machine, answered when a verb asks" do
    Given "the editor's macos build on the Linux box — the same dev.yml must load there"
    lock(image_pin("cellbound-3d-linux", target_platforms: ["linux64"]))
    targets = parse_targets(
      "cellbound-3d-editor" => {
        "platforms" => ["linux64", "macos"], "environment" => { "linux64" => "cellbound-3d-linux", "macos" => "host" },
      },
    )

    When
    bound = binder(host_os: "linux").bind_targets(targets)

    Then
    editor = bound["cellbound-3d-editor"]
    editor.placements[Dev::Lifecycle::Platform::Macos] == Dev::Placement::Host.new
    editor.host_platform == Dev::Lifecycle::Platform::Linux64
    !editor.buildable_here?(Dev::Lifecycle::Build.parse("cellbound-3d-editor-macos", targets.values))
    editor.buildable_here?(Dev::Lifecycle::Build.parse("cellbound-3d-editor-linux64", targets.values))
  end

  test "a target's environment the lock does not pin fails at binding, under the build's name" do
    Given
    lock(image_pin("snappy-linux"))
    targets = parse_targets("snappy-steam" => { "platforms" => ["win64"], "environment" => "snappy-win" })

    When
    binder.bind_targets(targets)

    Then
    error = raises(Dev::ProjectImages::UnknownImageError)
    error.message.include?("`snappy-steam-win64` runs in `snappy-win`")
  end

  test "a target naming none among several pins fails at binding, under its name" do
    Given
    lock(image_pin("snappy-linux"), image_pin("snappy-server"))
    targets = parse_targets("rspock" => {})

    When
    binder.bind_targets(targets)

    Then
    error = raises(Dev::ProjectImages::AmbiguousEnvironmentImageError)
    error.message.include?("`rspock` runs in a container but names no image")
  end

  test "a node that is not a parsed project node is a wiring bug" do
    Given "a builtin smuggled into the parsed tree"
    lock(image_pin("snappy-linux"))
    builtin = Class.new(Dev::BuiltinCommand) do
      def desc = "x"
      def category = Dev::Command::Category::Workflow
      def call(args:, context:); end
    end.new

    When
    binder.bind("x" => builtin)

    Then
    error = raises(Dev::PlacementBinder::NotAProjectNodeError)
    error.message.include?("command 'x'")
  end

  private

  def binder(host_os: "darwin")
    Dev::PlacementBinder.new(images: images, host_os: host_os)
  end

  def images
    Dev::ProjectImages.new(root: @root)
  end

  def parse(commands)
    parser = Dev::CommandParser.new
    commands.to_h { |name, hash| [name, parser.parse([name], hash)] }
  end

  def parse_targets(targets)
    Dev::TargetParser.new.parse_all(targets)
  end

  def lock(*pins)
    Dev::Deps::Lockfile.new(dir: @root).lock(Dev::EnvironmentImage.stamp(pins))
  end

  def image_pin(name, target_platforms: nil)
    metadata = {
      "from" => "ghcr.io/d3mlabs/unreal-engine-build-base", "platform" => "linux/amd64",
      "platforms" => ["linux/amd64"], "registry" => "ghcr.io/d3mlabs", "apt" => [],
    }
    metadata["target_platforms"] = target_platforms if target_platforms
    Dev::Deps::Dependency.new(
      name: name, integration: :image, group: :app, version: "ue5.8-3", hash: "SHA256=#{"a" * 64}", metadata: metadata,
    )
  end
end

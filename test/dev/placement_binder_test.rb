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
require "fileutils"
require "pathname"
require "tmpdir"

# The composition root's binding step over a parsed dev.yml tree and a
# real temp checkout's deps.lock.
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

  def binder
    Dev::PlacementBinder.new(images: images)
  end

  def images
    Dev::ProjectImages.new(root: @root)
  end

  def parse(commands)
    parser = Dev::CommandParser.new
    commands.to_h { |name, hash| [name, parser.parse([name], hash)] }
  end

  def lock(*pins)
    Dev::Deps::Lockfile.new(dir: @root).lock(Dev::EnvironmentImage.stamp(pins))
  end

  def image_pin(name)
    Dev::Deps::Dependency.new(
      name: name, integration: :image, group: :app, version: "ue5.8-3", hash: "SHA256=#{"a" * 64}",
      metadata: {
        "from" => "ghcr.io/d3mlabs/unreal-engine-build-base", "platform" => "linux/amd64",
        "platforms" => ["linux/amd64"], "registry" => "ghcr.io/d3mlabs", "apt" => [],
      },
    )
  end
end

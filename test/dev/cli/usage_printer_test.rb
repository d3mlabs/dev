# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/flag_vocabulary"
require "dev/cli/usage_printer"
require "dev/command"
require "dev/deps/dependency"
require "dev/environment_image"
require "dev/host_environment"
require "dev/host_rule"
require "dev/placement"
require "fileutils"
require "pathname"
require "stringio"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Cli::UsagePrinterTest < Minitest::Test
  # Minimal builtin fake: the printer only reads desc and category, so the
  # fake carries just those traits.
  class FakeBuiltin < Dev::BuiltinCommand
    def initialize(desc:, category:)
      super()
      @desc = desc
      @category = category
    end

    attr_reader :desc, :category

    def call(args:, context:); end
  end

  # Minimal lifecycle verb fake: its section is the shape's own.
  class FakeVerb < Dev::LifecycleCommand
    Env = type_member { { fixed: String } }

    def initialize(desc:)
      super()
      @desc = desc
    end

    attr_reader :desc

    def before(args:, context:) = Dev::Dispatch::Outcome::Done.new

    def seam(env, context:); end

    def after(env, context:); end
  end

  def setup
    @marker_dir = Pathname(Dir.mktmpdir("usage-printer-host"))
  end

  def teardown
    FileUtils.rm_rf(@marker_dir)
    super
  end

  def environment_builtin(desc: "an environment builtin")
    FakeBuiltin.new(desc: desc, category: Dev::Command::Category::Environment)
  end

  def workflow_builtin(desc: "a workflow builtin")
    FakeBuiltin.new(desc: desc, category: Dev::Command::Category::Workflow)
  end

  # Print the root over the given children the way bare `dev` does.
  def print_root(children, epilogue: "Examples: dev up    dev test", desc: "Development commands for myproject")
    out = StringIO.new
    Dev::Cli::UsagePrinter.new(epilogue: epilogue).print_node(
      path: [], command: Dev::CommandGroup.root(desc: desc, children: children), out: out,
    )
    out.string
  end

  test "a usage error prints the dev-prefixed message, then the node's usage, on the given stream" do
    Given "an unknown-flag error at a leaf, and a printer with an epilogue"
    leaf = workflow_builtin(desc: "Reclaim stale versions")
    error = Dev::Cli::FlagVocabulary::UnknownFlagError.new(flag: "--kep", path: ["cache", "gc"], command: leaf)
    err = StringIO.new

    When "printing it"
    Dev::Cli::UsagePrinter.new(epilogue: "Examples: dev up").print_usage_error(error, out: err)

    Then "the message heads the output and the node's usage follows (no epilogue: it is not the root)"
    err.string.lines.first == "dev: unknown flag '--kep' for 'dev cache gc'\n"
    err.string.include?("Usage: dev cache gc [args...]")
    err.string.include?("Reclaim stale versions")
    !err.string.include?("Examples")
  end

  test "the root renders the four sections in fixed order when its children span categories" do
    Given "one command per category"
    children = {
      "up" => environment_builtin(desc: "Provision"),
      "help" => workflow_builtin(desc: "Show this usage"),
      "test" => Dev::ProjectCommand.new(run: "rspec", desc: "Run tests"),
      "package" => FakeVerb.new(desc: "Package a build"),
    }

    When "printing the root"
    output = print_root(children)

    Then "the invocation and desc lead; each command renders under its section, sections in fixed order"
    lines = output.lines.map(&:chomp)
    lines.fetch(0) == "Usage: dev <command> [args...]"
    lines.fetch(2) == "Development commands for myproject"
    lines.index("Project commands:") < lines.index("  test         Run tests")
    lines.index("Lifecycle:") < lines.index("  package      Package a build")
    lines.index("Environment:") < lines.index("  up           Provision")
    lines.index("Development flow:") < lines.index("  help         Show this usage")
    lines.index("Project commands:") < lines.index("Lifecycle:")
    lines.index("Lifecycle:") < lines.index("Environment:")
    lines.index("Environment:") < lines.index("Development flow:")
    !lines.include?("Commands:")
  end

  test "a lifecycle verb carries no environment column: where it runs is its dispatch's, decided per build" do
    Given
    output = print_root({ "package" => FakeVerb.new(desc: "Package a build"), "up" => environment_builtin })

    Expect
    output.include?("  package      Package a build\n")
  end

  test "the root closes with the epilogue; other nodes do not" do
    Given "a printer with an epilogue and a group under the root"
    printer = Dev::Cli::UsagePrinter.new(epilogue: "Examples: dev up")
    group = build_group(["deps"])
    root_out = StringIO.new
    group_out = StringIO.new

    When "printing both"
    printer.print_node(path: [], command: Dev::CommandGroup.root(desc: "d", children: { "deps" => group }), out: root_out)
    printer.print_node(path: ["deps"], command: group, out: group_out)

    Then "the epilogue is the root's last line, absent from the group's usage"
    root_out.string.lines.last == "Examples: dev up\n"
    !group_out.string.include?("Examples")
  end

  test "a root printed without an epilogue ends at its listing" do
    Given "no epilogue"
    output = print_root({ "up" => environment_builtin }, epilogue: nil)

    Expect
    output.lines.last == "  up           an environment builtin\n"
  end

  test "commands list alphabetically within a section" do
    Given "environment commands registered out of alphabetical order"
    children = {
      "update-deps" => environment_builtin,
      "check" => environment_builtin,
      "install-deps" => environment_builtin,
    }

    When "printing the root"
    lines = print_root(children).lines.map(&:chomp)

    Then "the section lists them alphabetically"
    lines.index("  check        an environment builtin") <
      lines.index("  install-deps an environment builtin")
    lines.index("  install-deps an environment builtin") <
      lines.index("  update-deps  an environment builtin")
  end

  test "children of one category list under a plain Commands heading, whatever the category" do
    Given "roots whose children share a category"
    project_only = print_root({ "test" => Dev::ProjectCommand.new(run: "rspec", desc: "Run tests") })
    environment_only = print_root({ "up" => environment_builtin })

    Expect "no section headings"
    project_only.include?("\nCommands:\n  test         Run tests\n")
    !project_only.include?("Project commands:")
    environment_only.include?("\nCommands:\n")
    !environment_only.include?("Environment:")
  end

  test "sections without commands are omitted" do
    Given "children spanning two of the four categories"
    output = print_root({ "test" => Dev::ProjectCommand.new(run: "rspec", desc: "Run tests"), "help" => workflow_builtin })

    Expect "no empty section header renders"
    output.include?("Project commands:")
    output.include?("Development flow:")
    !output.include?("Environment:")
  end

  test "an overridden slot lists under the builtin's section with the project's desc" do
    Given "an environment slot overridden by a project command, beside a project command"
    overridden = Dev::OverriddenCommand.new(
      builtin: environment_builtin(desc: "builtin up"),
      project: Dev::ProjectCommand.new(run: "./bin/up.rb", desc: "Project setup"),
    )

    When "printing the root"
    output = print_root({ "up" => overridden, "test" => Dev::ProjectCommand.new(run: "rspec", desc: "Run tests") })

    Then "the slot renders under Environment with the override's description"
    lines = output.lines.map(&:chomp)
    lines.index("Environment:") < lines.index("  up           Project setup")
    !output.include?("builtin up")
  end

  test "nodes with children list with a trailing ellipsis, groups and runnable commands alike" do
    Given "a group and a runnable command heading a child"
    group = build_group(["deps"], category: Dev::Command::Category::Environment, desc: "Dependency lookups")
    test = Dev::ProjectCommand.new(run: "./bin/test.sh", desc: "All tests", children: { "unit" => workflow_builtin })

    When "printing the root"
    output = print_root({ "deps" => group, "test" => test })

    Then "the marker tells the reader there is more beneath"
    output.include?("  deps …       Dependency lookups")
    output.include?("  test …       All tests")
  end

  test "print_node renders a group's usage line and its visible children" do
    Given "a group with a hidden child"
    printer = Dev::Cli::UsagePrinter.new
    group = build_group(
      ["deps"],
      desc: "Dependency lookups",
      children: {
        "path" => environment_builtin(desc: "Print a locked artifact's path"),
        "plumbing" => Dev::ProjectCommand.new(run: "x", desc: "internal", hidden: true),
        "check" => build_group(["deps", "check"], desc: "Checks", category: Dev::Command::Category::Environment),
      },
    )
    out = StringIO.new

    When "printing the node"
    printer.print_node(path: ["deps"], command: group, out: out)

    Then "usage names the path, the desc follows, children list alphabetically, hidden ones omitted, groups marked"
    lines = out.string.lines.map(&:chomp)
    lines.fetch(0) == "Usage: dev deps <command> [args...]"
    lines.fetch(1) == ""
    lines.fetch(2) == "Dependency lookups"
    lines.index("Commands:") < lines.index("  check …      Checks")
    lines.index("  check …      Checks") < lines.index("  path         Print a locked artifact's path")
    !out.string.include?("plumbing")
  end

  test "a multi-line desc lists by its first line and prints in full on the node's own usage" do
    Given "a group whose desc carries a summary line and a detail line"
    printer = Dev::Cli::UsagePrinter.new
    group = build_group(["learnings"], desc: "The read path\nCapture is agent-driven.", category: Dev::Command::Category::Workflow)
    root_out = StringIO.new
    group_out = StringIO.new

    When "printing the root listing and the group's own usage"
    printer.print_node(path: [], command: Dev::CommandGroup.root(desc: "d", children: { "learnings" => group }), out: root_out)
    printer.print_node(path: ["learnings"], command: group, out: group_out)

    Then "the listing shows only the summary; the group's usage shows both lines"
    root_out.string.include?("  learnings …  The read path\n")
    !root_out.string.include?("Capture is agent-driven.")
    group_out.string.lines.map(&:chomp).fetch(2) == "The read path"
    group_out.string.lines.map(&:chomp).fetch(3) == "Capture is agent-driven."
  end

  test "print_node renders both invocations of a runnable command with children" do
    Given "a project command heading a child"
    printer = Dev::Cli::UsagePrinter.new
    test = Dev::ProjectCommand.new(
      run: "./bin/test.sh", desc: "Run every suite",
      children: { "unit" => Dev::ProjectCommand.new(run: "rspec", desc: "Unit") },
    )
    out = StringIO.new

    When "printing the node"
    printer.print_node(path: ["test"], command: test, out: out)

    Then "the bare form leads, the subcommand form follows"
    lines = out.string.lines.map(&:chomp)
    lines.fetch(0) == "Usage: dev test [args...]"
    lines.fetch(1) == "       dev test <command> [args...]"
    lines.fetch(3) == "Run every suite"
    lines.include?("  unit         Unit")
  end

  test "print_node lists a command's flags after its description: switches by name, value-taking ones with a placeholder, each with its description" do
    Given "a builtin declaring three flags, one undescribed"
    printer = Dev::Cli::UsagePrinter.new
    command = FakeBuiltin.new(desc: "Enroll this host", category: Dev::Command::Category::Environment)
    command.stubs(:flags).returns([
      Dev::Cli::Flag.new("--org", desc: "enroll at the org scope"),
      Dev::Cli::Flag.new("--labels", takes_value: true, desc: "comma-separated runner labels"),
      Dev::Cli::Flag.new("--yes"),
    ])
    out = StringIO.new

    When "printing the node"
    printer.print_node(path: ["runner", "register"], command: command, out: out)

    Then "a Flags section follows the description, in declaration order, names padded to one column"
    out.string == <<~USAGE
      Usage: dev runner register [args...]

      Enroll this host

      Flags:
        --org             enroll at the org scope
        --labels <value>  comma-separated runner labels
        --yes
    USAGE
  end

  test "print_node renders a childless command as its one invocation and description" do
    Given "a leaf"
    printer = Dev::Cli::UsagePrinter.new
    out = StringIO.new

    When "printing the node"
    printer.print_node(path: ["test", "unit"], command: Dev::ProjectCommand.new(run: "rspec", desc: "Unit tests"), out: out)

    Then "no Commands section"
    out.string == "Usage: dev test unit [args...]\n\nUnit tests\n"
  end

  # --- the environment column (dev#409) ----------------------------------

  test "project rows carry their environment on this machine as a trailing column; builtins and groups carry none" do
    Given "a host provisioned from one of two images; commands placed on each, on the host, and unplaced shapes beside them"
    linux = image("cellbound-3d-linux")
    server = image("cellbound-3d-server")
    host_rule = host_rule(provisioned_from: server)
    children = {
      "build" => bound(Dev::ProjectCommand.new(run: "./bin/build", desc: "Build"), Dev::Placement::Image.new(image: linux)),
      "serve" => bound(Dev::ProjectCommand.new(run: "./bin/serve", desc: "Run the dedicated server"), Dev::Placement::Image.new(image: server)),
      "s" => bound(Dev::ProjectCommand.new(run: "./bin/dev-s", desc: "Inner loop"), Dev::Placement::Host.new),
      "db" => build_group(["db"], desc: "Database chores"),
      "up" => Dev::OverriddenCommand.new(
        builtin: environment_builtin(desc: "builtin up"),
        project: bound(Dev::ProjectCommand.new(run: "./bin/setup", desc: "Setup"), Dev::Placement::Host.new),
      ),
      "deps" => environment_builtin(desc: "Manage dependencies"),
    }

    When "printing the root to a non-terminal"
    out = StringIO.new
    Dev::Cli::UsagePrinter.new(host_rule:).print_node(path: [], command: Dev::CommandGroup.root(desc: "d", children:), out:)
    lines = out.string.lines.map(&:chomp)

    Then "one column per section, padded to its longest summary: the image (container) when entered from here, the image when native, host; nothing on a group or a plain builtin"
    lines.include?("  build        Build                     cellbound-3d-linux (container)")
    lines.include?("  serve        Run the dedicated server  cellbound-3d-server")
    lines.include?("  s            Inner loop                host")
    lines.include?("  db …         Database chores")
    lines.include?("  up           Setup#{" " * 16}host")
    lines.include?("  deps         Manage dependencies")
    !out.string.include?("\e[")
  end

  test "the environment column is dim on a terminal and plain anywhere else" do
    Given
    command = bound(Dev::ProjectCommand.new(run: "./bin/dev-s", desc: "Inner loop"), Dev::Placement::Host.new)
    root = Dev::CommandGroup.root(desc: "d", children: { "s" => command })
    tty = StringIO.new
    tty.define_singleton_method(:tty?) { true }
    pipe = StringIO.new

    When
    Dev::Cli::UsagePrinter.new(host_rule: host_rule).print_node(path: [], command: root, out: tty)
    Dev::Cli::UsagePrinter.new(host_rule: host_rule).print_node(path: [], command: root, out: pipe)

    Then
    tty.string.include?("  s            Inner loop  \e[2mhost\e[0m\n")
    pipe.string.include?("  s            Inner loop  host\n")
  end

  test "a command the composition root could not bind lists without a column: the lock said why on stderr" do
    Expect
    print_root({ "test" => Dev::ProjectCommand.new(run: "rspec", desc: "Run tests") }).include?("  test         Run tests\n")
  end

  test "a node's own usage says its environment in a sentence: #{what}" do
    Given
    linux = image("cellbound-3d-linux")
    host_rule = host_rule(provisioned_from: native ? linux : nil)
    command = bound(Dev::ProjectCommand.new(run: "./bin/build", desc: "Build"), placement_for(placement, linux))
    out = StringIO.new

    When
    Dev::Cli::UsagePrinter.new(host_rule:).print_node(path: ["build"], command:, out:)

    Then "the sentence follows the description"
    out.string == "Usage: dev build [args...]\n\nBuild\n#{sentence}\n"

    Where
    what                         | placement | native | sentence
    "the host"                   | :host     | false  | "Runs on the host."
    "an image entered from here" | :image    | false  | "Runs in cellbound-3d-linux, in a container on this machine."
    "an image this host is"      | :image    | true   | "Runs in cellbound-3d-linux, natively on this machine."
  end

  # --- a lifecycle verb's listing (dev#414) -----------------------------

  test "a verb's own usage lists its subjects after its flags, in its order, labels fitted, each with its environment" do
    Given "a host provisioned from neither image, and a verb listing four builds"
    linux = image("cellbound-3d-linux")
    verb = FakeVerb.new(desc: "Build a target")
    verb.stubs(:flags).returns([Dev::Cli::Flag.new("--target", takes_value: true, desc: "the target")])
    verb.stubs(:listing).returns(
      Dev::LifecycleCommand::Listing.new(
        heading: "Builds",
        subjects: [
          Dev::LifecycleCommand::Subject.new(name: "cellbound-3d-win64-dev", desc: "Client", placement: Dev::Placement::Image.new(image: linux)),
          Dev::LifecycleCommand::Subject.new(name: "cellbound-3d-editor-macos", desc: "Editor", placement: Dev::Placement::Host.new),
          Dev::LifecycleCommand::Subject.new(
            name: "cellbound-3d-editor-linux64", desc: "Editor", placement: Dev::Placement::Host.new, note: "(linux64 only)",
          ),
          Dev::LifecycleCommand::Subject.new(name: "rspock", desc: "The gem"),
        ],
      ),
    )
    out = StringIO.new

    When
    Dev::Cli::UsagePrinter.new(host_rule: host_rule).print_node(path: ["build"], command: verb, out:)

    Then "the section follows the flags; declaration order kept; the environment as a command's column — (remote), since a verb leaves for the image's host rather than entering a container — the note after it"
    out.string == <<~USAGE
      Usage: dev build [args...]

      Build a target

      Flags:
        --target <value>  the target

      Builds:
        cellbound-3d-win64-dev      Client   cellbound-3d-linux (remote)
        cellbound-3d-editor-macos   Editor   host
        cellbound-3d-editor-linux64 Editor   host (linux64 only)
        rspock                      The gem
    USAGE
  end

  test "a verb with nothing to list prints no listing section" do
    Given
    out = StringIO.new

    When
    Dev::Cli::UsagePrinter.new(host_rule: host_rule).print_node(path: ["deploy"], command: FakeVerb.new(desc: "Ship"), out:)

    Then
    out.string == "Usage: dev deploy [args...]\n\nShip\n"
  end

  # --- a channel's details and placement (dev#415) -----------------------

  test "a verb with a placement and details lists them: the environment as its column, each detail on its own line under the row, rows in name order" do
    Given "a deploy group of two channels, one placed in an image this host is not, one on the host, beside an unplaced verb"
    linux = image("cellbound-3d-linux")
    staging = FakeVerb.new(desc: "rsync to the gamebox")
    staging.stubs(:placement).returns(Dev::Placement::Host.new)
    staging.stubs(:details).returns(["Accepts: cellbound-3d-win64-dev, cellbound-3d-linux64-dev", "Protocol: run: ./bin/stage"])
    steam = FakeVerb.new(desc: "Steam depots")
    steam.stubs(:placement).returns(Dev::Placement::Image.new(image: linux))
    steam.stubs(:details).returns(["Accepts: cellbound-3d-steamworks-win64-release", "Protocol: run: ./bin/steam-upload"])
    group = build_group(["deploy"], desc: "Ship an artifact to a channel", category: Dev::Command::Category::Lifecycle,
      children: { "staging" => staging, "steam" => steam, "mirror" => FakeVerb.new(desc: "A bare verb") })
    out = StringIO.new

    When
    Dev::Cli::UsagePrinter.new(host_rule: host_rule).print_node(path: ["deploy"], command: group, out:)

    Then
    out.string == <<~USAGE
      Usage: dev deploy <command> [args...]

      Ship an artifact to a channel

      Commands:
        mirror       A bare verb
        staging      rsync to the gamebox  host
                     Accepts: cellbound-3d-win64-dev, cellbound-3d-linux64-dev
                     Protocol: run: ./bin/stage
        steam        Steam depots          cellbound-3d-linux (remote)
                     Accepts: cellbound-3d-steamworks-win64-release
                     Protocol: run: ./bin/steam-upload
    USAGE
  end

  test "a placed verb's own usage says its environment in a sentence, then its details, before its flags" do
    Given
    staging = FakeVerb.new(desc: "rsync to the gamebox")
    staging.stubs(:placement).returns(Dev::Placement::Host.new)
    staging.stubs(:details).returns(["Accepts: rspock", "Protocol: run: ./bin/stage"])
    staging.stubs(:flags).returns([Dev::Cli::Flag.new("--dry-run", desc: "select and report, ship nothing")])
    out = StringIO.new

    When
    Dev::Cli::UsagePrinter.new(host_rule: host_rule).print_node(path: ["deploy", "staging"], command: staging, out:)

    Then
    out.string == <<~USAGE
      Usage: dev deploy staging [args...]

      rsync to the gamebox
      Runs on the host.
      Accepts: rspock
      Protocol: run: ./bin/stage

      Flags:
        --dry-run  select and report, ship nothing
    USAGE
  end

  test "a verb placed in an image this host is not says it runs on a remote host, where a project command would say a container" do
    Given
    linux = image("cellbound-3d-linux")
    steam = FakeVerb.new(desc: "Steam depots")
    steam.stubs(:placement).returns(Dev::Placement::Image.new(image: linux))
    out = StringIO.new

    When
    Dev::Cli::UsagePrinter.new(host_rule: host_rule).print_node(path: ["deploy", "steam"], command: steam, out:)

    Then
    out.string.lines.map(&:chomp).fetch(3) == "Runs in cellbound-3d-linux, on a remote host (this machine was not provisioned from it)."
  end

  test "an overridden slot's own usage says the project body's environment" do
    Given
    overridden = Dev::OverriddenCommand.new(
      builtin: environment_builtin(desc: "builtin up"),
      project: bound(Dev::ProjectCommand.new(run: "./bin/setup", desc: "Setup"), Dev::Placement::Host.new),
    )
    out = StringIO.new

    When
    Dev::Cli::UsagePrinter.new(host_rule: host_rule).print_node(path: ["up"], command: overridden, out:)

    Then
    out.string.lines.map(&:chomp).fetch(3) == "Runs on the host."
  end

  def build_group(path, desc: "a group", category: Dev::Command::Category::Project, children: nil)
    Dev::CommandGroup.new(
      path: path, desc: desc, category: category, children: children || { "child" => workflow_builtin },
    )
  end

  def bound(command, placement)
    command.with_placement(placement)
  end

  def placement_for(kind, image)
    kind == :host ? Dev::Placement::Host.new : Dev::Placement::Image.new(image:)
  end

  def image(name)
    Dev::EnvironmentImage.from_pin(
      Dev::Deps::Dependency.new(
        name: name, integration: :image, group: :app, version: "ue5.8-3", hash: "SHA256=#{"a" * 64}",
        metadata: {
          "from" => "ghcr.io/d3mlabs/unreal-engine-build-base", "platform" => "linux/amd64",
          "platforms" => ["linux/amd64"], "registry" => "ghcr.io/d3mlabs", "apt" => [],
        },
      ),
    )
  end

  # A host rule over a real marker file: a host provisioned from +image+,
  # or a bare one.
  def host_rule(provisioned_from: nil)
    marker = @marker_dir / "environment-#{provisioned_from&.name || "none"}"
    marker.write(provisioned_from.marker) if provisioned_from
    Dev::HostRule.new(host_environment: Dev::HostEnvironment.new(path: marker.to_s), inside_container: false)
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/build_dispatcher"
require "dev/build_listing"
require "dev/build_selector"
require "dev/builtins/build_command"
require "dev/dispatch"
require "dev/dispatch_resolver"
require "dev/host_environment"
require "dev/host_rule"
require "dev/lifecycle"
require "dev/lifecycle_executor"
require "dev/placement"
require "dev/target_placement"
require "fileutils"
require "pathname"
require "stringio"
require "tmpdir"

# The verb end to end through the LifecycleExecutor, over a real project
# root with a real build script and a real store in a temp data root.
# Every target is placed on the host and the machine is declared linux64,
# so the dispatch is native wherever the suite runs.
transform!(RSpock::AST::Transformation)
class Dev::Builtins::BuildCommandTest < Minitest::Test
  include SorbetHelper

  PLATFORM = Dev::Lifecycle::Platform
  CONFIG = Dev::Lifecycle::Config

  def setup
    @root = Pathname(Dir.mktmpdir("build-command-"))
    @project = @root / "project"
    @project.mkpath
    (@project / "build.sh").write(<<~SH)
      #!/bin/sh
      set -eu
      echo "$DEV_TARGET ${DEV_PLATFORM:-} ${DEV_CONFIG:-}" > "$DEV_INSTALL/built.txt"
      echo "$DEV_INSTALL" >> "$DEV_INSTALL/built.txt"
    SH
    @out = StringIO.new
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  def client
    Dev::Lifecycle::Target.new(
      name: "cellbound-3d", desc: "Client", platforms: [PLATFORM::Linux64], configs: [CONFIG::Development, CONFIG::Release],
      builder: Dev::Lifecycle::BuilderSpec::Script.new(command: "sh ./build.sh"),
    )
  end

  def refusing
    Dev::Lifecycle::Target.new(name: "opencell", desc: "Sim", builder: Dev::Lifecycle::BuilderSpec::Script.new(command: "exit 2"))
  end

  def gem_target = Dev::Lifecycle::Target.new(name: "rspock", desc: "The gem")

  def targets = [client, refusing, gem_target]

  def store = Dev::Lifecycle::Store.new(project_name: "cellbound-3d", targets: targets, data_root: (@root / "data").to_s)

  def dispatcher(placements: host_placements)
    host_rule = Dev::HostRule.new(host_environment: Dev::HostEnvironment.new(path: (@root / "no-marker").to_s), inside_container: false)
    Dev::BuildDispatcher.new(placements: placements, resolver: Dev::DispatchResolver.new(host_rule: host_rule))
  end

  def host_placements
    targets.to_h do |target|
      axis = target.platforms? ? target.platforms : [nil]
      placements = axis.to_h { |platform| [platform, Dev::Placement::Host.new] }
      [target.name, Dev::TargetPlacement.new(target: target, placements: placements, host_platform: PLATFORM::Linux64)]
    end
  end

  def command(dispatcher: self.dispatcher)
    selector = Dev::BuildSelector.new(targets: targets)
    Dev::Builtins::BuildCommand.new(
      selector: selector,
      dispatcher: dispatcher,
      listing: Dev::BuildListing.new(targets: targets, dispatcher: dispatcher),
      ports: Dev::Lifecycle::Ports.new(project_root: @project),
      store: store,
      out: @out,
    )
  end

  def context
    Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui), project: Dev::ProjectContext.new(name: "cellbound-3d", root: @project))
  end

  def execute(verb, *words)
    Dev::LifecycleExecutor.new.execute(verb, args: parsed_args(verb, words), context: context)
  end

  test "bare `dev build` builds the first declared target's default build into the store's install dir, env from the build" do
    Given
    verb = command

    When
    execute(verb)

    Then "the script ran with the build's axes and wrote into DEV_INSTALL; the verb reports the install"
    install = store.install_dir(Dev::Lifecycle::Build.parse("cellbound-3d-linux64-dev", targets))
    (install / "built.txt").read == "cellbound-3d linux64 dev\n#{install}\n"
    @out.string == "built cellbound-3d-linux64-dev → #{install}\n"
  end

  test "#{words.inspect} builds #{expected}" do
    When
    execute(command, *words)

    Then
    @out.string.start_with?("built #{expected} → ")
    (store.install_dir(Dev::Lifecycle::Build.parse(expected, targets)) / "built.txt").file?

    Where
    words                                 | expected
    ["cellbound-3d-release"]              | "cellbound-3d-linux64-release"
    ["--target", "cellbound-3d", "--config", "release"] | "cellbound-3d-linux64-release"
    ["cellbound-3d", "--platform", "linux64"]           | "cellbound-3d-linux64-dev"
  end

  test "a target with no build: has nothing to compile: the verb says so and touches nothing" do
    When
    execute(command, "rspock")

    Then
    @out.string == "rspock: nothing to build (target 'rspock' declares no `build:`)\n"
    !store.install_dir(Dev::Lifecycle::Build.parse("rspock", targets)).exist?
  end

  test "a builder that fails short-circuits the report: the error bubbles" do
    When
    execute(command, "opencell")

    Then
    raises Dev::Lifecycle::ScriptBuilder::BuildScriptFailedError
    @out.string == ""
  end

  test "a build this machine cannot produce where it is placed is refused before the builder runs" do
    Given "the client's linux64 build on the host of a Mac"
    placements = host_placements
    placements["cellbound-3d"] = Dev::TargetPlacement.new(
      target: client, placements: { PLATFORM::Linux64 => Dev::Placement::Host.new }, host_platform: PLATFORM::Macos,
    )

    When
    execute(command(dispatcher: dispatcher(placements: placements)), "cellbound-3d")

    Then
    raises Dev::TargetPlacement::HostDoesNotProduceError
    !store.install_dir(Dev::Lifecycle::Build.parse("cellbound-3d-linux64-dev", targets)).exist?
  end

  test "the verb's traits: Lifecycle section, the selector's flags, the builds listed with their environment, completions over the patterns" do
    Given
    verb = command

    Expect
    verb.category == Dev::Command::Category::Lifecycle
    verb.flags == Dev::BuildSelector::FLAGS
    verb.desc.lines.first.chomp == "Build a target's install (build [BUILD] | --target T [--platform P] [--config C])"
    verb.desc.include?("Bare `dev build` is `cellbound-3d-linux64-dev`.")
    verb.listing.heading == "Builds"
    verb.listing.subjects.map(&:name) == ["cellbound-3d-linux64-dev", "cellbound-3d-linux64-release", "opencell", "rspock"]
    verb.listing.subjects.map(&:desc) == ["Client", "Client", "Sim", "The gem"]
    verb.listing.subjects.map(&:placement).uniq == [Dev::Placement::Host.new]
    verb.listing.subjects.map(&:note).uniq == [nil]
    verb.completions([]) == ["cellbound-3d", "cellbound-3d-dev", "cellbound-3d-release", "cellbound-3d-linux64",
                             "cellbound-3d-linux64-dev", "cellbound-3d-linux64-release", "opencell", "rspock"]
  end

  test "the listing notes a host build this machine cannot produce, and leaves an unbound target without a column" do
    Given "the client on a Mac; the other targets unbound (the lock was unreadable)"
    placements = {
      "cellbound-3d" => Dev::TargetPlacement.new(
        target: client, placements: { PLATFORM::Linux64 => Dev::Placement::Host.new }, host_platform: PLATFORM::Macos,
      ),
    }
    verb = command(dispatcher: dispatcher(placements: placements))

    Expect
    verb.listing.subjects.map { |subject| [subject.name, subject.placement, subject.note] } == [
      ["cellbound-3d-linux64-dev", Dev::Placement::Host.new, "(linux64 only)"],
      ["cellbound-3d-linux64-release", Dev::Placement::Host.new, "(linux64 only)"],
      ["opencell", nil, nil],
      ["rspock", nil, nil],
    ]
  end
end

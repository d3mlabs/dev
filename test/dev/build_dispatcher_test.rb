# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/build_dispatcher"
require "dev/cli/ui"
require "dev/deps/dependency"
require "dev/dispatch"
require "dev/dispatch_resolver"
require "dev/enrolled_runner_lookup"
require "dev/environment_image"
require "dev/host_environment"
require "dev/host_rule"
require "dev/lifecycle"
require "dev/placement"
require "dev/project_container"
require "dev/remote_dispatches"
require "dev/settings"
require "dev/target_placement"
require "fileutils"
require "pathname"
require "stringio"
require "support/fake_gh"
require "support/lifecycle_fixtures"
require "tmpdir"

# The verbs' shared placement step against a real host marker in a temp
# dir, as DispatchResolverTest drives the resolver.
transform!(RSpock::AST::Transformation)
class Dev::BuildDispatcherTest < Minitest::Test
  include LifecycleFixtures
  include SorbetHelper

  # The repo has no enrolled runner online.
  class NoneEnrolled < Dev::EnrolledRunnerLookup
    def available = nil
  end

  def setup
    @dir = Pathname(Dir.mktmpdir("build-dispatcher"))
    @marker = (@dir / "environment").to_s
  end

  def teardown
    FileUtils.rm_rf(@dir)
    super
  end

  def image
    Dev::EnvironmentImage.from_pin(
      Dev::Deps::Dependency.new(
        name: "cellbound-3d-linux", integration: :image, group: :app, version: "ue5.8-3", hash: "SHA256=#{"a" * 64}",
        metadata: {
          "from" => "ghcr.io/d3mlabs/unreal-engine-build-base", "platform" => "linux/amd64", "platforms" => ["linux/amd64"],
          "registry" => "ghcr.io/d3mlabs", "apt" => [], "target_platforms" => ["win64", "linux64"],
        },
      ),
    )
  end

  # The client in the image, the gem on the host; the machine is a Mac.
  def placements(host_platform: PLATFORM::Macos)
    {
      "cellbound-3d" => Dev::TargetPlacement.new(
        target: client_target,
        placements: { PLATFORM::Win64 => Dev::Placement::Image.new(image: image), PLATFORM::Linux64 => Dev::Placement::Host.new },
        host_platform: host_platform,
      ),
      "rspock" => Dev::TargetPlacement.new(target: gem_target, placements: { nil => Dev::Placement::Host.new }, host_platform: host_platform),
    }
  end

  def dispatcher(placements: self.placements)
    host_rule = Dev::HostRule.new(host_environment: Dev::HostEnvironment.new(path: @marker), inside_container: false)
    remotes = Dev::RemoteDispatches.new(
      root: @dir, ui: typed_mock(Dev::Cli::Ui), out: StringIO.new, runs: Dev::Lifecycle::WorkflowRuns.new(gh: FakeGh.new(root: @dir)),
      containers: Dev::ProjectContainer.new(project_root: @dir),
    )
    settings = Dev::Settings.new(config_path: (@dir / "config.yml").to_s, system_config_path: (@dir / "none.yml").to_s)
    resolver = Dev::DispatchResolver.new(host_rule: host_rule, remotes: remotes, enrolled: NoneEnrolled.new, settings: settings, inside_job: false)
    Dev::BuildDispatcher.new(placements: placements, resolver: resolver)
  end

  test "placement_for and buildable_here? read the bound target placement" do
    Expect
    dispatcher.bound?(build("rspock"))
    !dispatcher(placements: {}).bound?(build("rspock"))
    dispatcher.placement_for(build("cellbound-3d-win64-dev")) == Dev::Placement::Image.new(image: image)
    dispatcher.placement_for(build("rspock")) == Dev::Placement::Host.new
    dispatcher.buildable_here?(build("rspock"))
    !dispatcher.buildable_here?(build("cellbound-3d-linux64-dev"))
    dispatcher(placements: placements(host_platform: PLATFORM::Linux64)).buildable_here?(build("cellbound-3d-linux64-dev"))
  end

  test "a host build this machine produces dispatches native" do
    Expect
    dispatcher.dispatch_for(build("rspock")) == Dev::Dispatch::Native.new
  end

  test "an image build is native on a host provisioned from the image" do
    Given
    File.write(@marker, image.marker)

    Expect
    dispatcher.dispatch_for(build("cellbound-3d-win64-dev")) == Dev::Dispatch::Native.new
  end

  test "an image build on a bare host with no runner to go to goes to the project's container of the image" do
    When
    dispatch = dispatcher.dispatch_for(build("cellbound-3d-win64-dev"))

    Then
    dispatch.is_a?(Dev::Dispatch::Remote)
    dispatch.transport.is_a?(Dev::Transport::LocalContainer)
  end

  test "`--container` sends an image build the host could do natively to the container, no questions asked" do
    Given "a host provisioned from the image"
    File.write(@marker, image.marker)

    When
    dispatch = dispatcher.dispatch_for(build("cellbound-3d-win64-dev"), container: true)

    Then
    dispatch.is_a?(Dev::Dispatch::Remote)
    dispatch.transport.is_a?(Dev::Transport::LocalContainer)
  end

  test "`--container` for a host build this machine cannot do is refused for the lack of an image, not the platform" do
    When
    dispatcher.dispatch_for(build("cellbound-3d-linux64-dev"), container: true)

    Then
    raises Dev::DispatchResolver::NoContainerForHostError
  end

  test "a host build of a platform this machine is not is refused before any dispatch" do
    When
    dispatcher.dispatch_for(build("cellbound-3d-linux64-dev"))

    Then
    error = raises(Dev::TargetPlacement::HostDoesNotProduceError)
    error.message.include?("`cellbound-3d-linux64-dev` builds on the host, and this host is macos")
  end

  test "`--runner` sends #{what} to the label without asking whether this machine could produce it: the runner does" do
    When
    dispatch = dispatcher.dispatch_for(build(name), runner: "linux-pool")

    Then
    dispatch.is_a?(Dev::Dispatch::Remote)
    dispatch.transport.runner == "linux-pool"

    Where
    what                                  | name
    "an image build on a bare host"       | "cellbound-3d-win64-dev"
    "a host build this machine cannot do" | "cellbound-3d-linux64-dev"
    "a host build this machine can do"    | "rspock"
  end

  test "a target with no placement bound (the lock was unreadable at load) refuses with the re-lock" do
    When
    dispatcher(placements: {}).dispatch_for(build("rspock"))

    Then
    error = raises(Dev::BuildDispatcher::UnboundTargetError)
    error.message == "`rspock` has no environment bound: the lock could not place it at load — re-lock it (dev deps update) and retry"
  end
end

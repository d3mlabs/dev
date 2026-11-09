# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/ui"
require "dev/deps/dependency"
require "dev/cli/dispatch"
require "dev/cli/dispatch_resolver"
require "dev/enrolled_runner"
require "dev/enrolled_runner_lookup"
require "dev/environment_image"
require "dev/host_environment"
require "dev/cli/host_rule"
require "dev/cli/placement"
require "dev/project_container"
require "dev/cli/remote_dispatches"
require "dev/runner_registry"
require "dev/settings"
require "fileutils"
require "pathname"
require "stringio"
require "support/fake_gh"
require "tmpdir"

# The one decision site of where a verb runs, against a real host marker
# in a temp dir: `/etc/dev/environment` is what the host rule reads, so
# each case writes (or leaves absent) the marker that makes it so. The
# remote side is real too — a Settings over a temp config file, an
# EnrolledRunnerLookup over a scripted registry — so the order native →
# `--runner` → `--container` → setting → enrolled → local container is
# read off the actual collaborators.
transform!(RSpock::AST::Transformation)
class Dev::Cli::DispatchResolverTest < Minitest::Test
  include SorbetHelper

  # On the class: Where cells are evaluated there.
  class << self
    def image(name: "cellbound-3d-linux", apt: ["dos2unix"])
      Dev::EnvironmentImage.from_pin(
        Dev::Deps::Dependency.new(
          name: name, integration: :image, group: :app, version: "ue5.8-3", hash: "SHA256=#{"a" * 64}",
          metadata: {
            "from" => "ghcr.io/d3mlabs/unreal-engine-build-base", "platform" => "linux/amd64",
            "platforms" => ["linux/amd64"], "registry" => "ghcr.io/d3mlabs", "apt" => apt,
          },
        ),
      )
    end
  end

  # A registry that lists the enrolled runner online, or nothing.
  class ScriptedRegistry < Dev::RunnerRegistry
    def initialize(online:)
      super()
      @online = online
    end

    def available(scope:, label:)
      @online ? Dev::RunnerRegistry::Runner.new(id: 7, custom_labels: [label], status: "online") : nil
    end
  end

  def setup
    @dir = Pathname(Dir.mktmpdir("dispatch-resolver"))
    @marker = (@dir / "environment").to_s
    @config = (@dir / "config.yml").to_s
  end

  def teardown
    FileUtils.rm_rf(@dir)
    super
  end

  # The same image for the test bodies, which run on the instance.
  def image(name: "cellbound-3d-linux", apt: ["dos2unix"])
    self.class.image(name: name, apt: apt)
  end

  def resolver(inside_container: false, standing: nil, enrolled_online: false, inside_job: false)
    host_rule = Dev::Cli::HostRule.new(
      host_environment: Dev::HostEnvironment.new(path: @marker), inside_container: inside_container,
    )
    settings = Dev::Settings.new(config_path: @config, system_config_path: (@dir / "none.yml").to_s)
    settings.set(Dev::Settings::LIFECYCLE_RUNNER_KEY, standing) if standing
    enrolled = Dev::EnrolledRunnerLookup.new(registry: ScriptedRegistry.new(online: enrolled_online), repo_resolver: -> { "d3mlabs/Cellbound-3D" })
    remotes = Dev::Cli::RemoteDispatches.new(
      root: @dir, ui: typed_mock(Dev::Ui), out: StringIO.new,
      runs: Dev::Lifecycle::WorkflowRuns.new(gh: FakeGh.new(root: @dir)),
      containers: Dev::ProjectContainer.new(project_root: @dir),
    )
    Dev::Cli::DispatchResolver.new(host_rule: host_rule, remotes: remotes, enrolled: enrolled, settings: settings, inside_job: inside_job)
  end

  test "a build placed on the host is native wherever dev runs" do
    Expect
    resolver.resolve(Dev::Cli::Placement::Host.new, subject: "rspock") == Dev::Cli::Dispatch::Native.new
  end

  test "a build placed in an image is native exactly when the host rule passes: #{what}" do
    Given
    File.write(@marker, marker_text) if marker_text
    placement = Dev::Cli::Placement::Image.new(image: image)

    Expect
    resolver(inside_container: inside).resolve(placement, subject: "cellbound-3d-win64-dev") == Dev::Cli::Dispatch::Native.new

    Where
    what                                | marker_text  | inside
    "a host provisioned from the image" | image.marker | false
    "inside a container of the image"   | image.marker | true
  end

  test "`--runner` forces the remote dispatch to that label, whatever the placement: #{what}" do
    Given "a host that could run both natively"
    File.write(@marker, image.marker)

    When
    dispatch = resolver(standing: "standing-pool", enrolled_online: true).resolve(placement, subject: "x", runner: "win64-pool")

    Then
    dispatch.is_a?(Dev::Cli::Dispatch::Remote)
    dispatch.transport.is_a?(Dev::Cli::Transport::ActionsRunner)
    dispatch.transport.runner == "win64-pool"

    Where
    what        | placement
    "the host"  | Dev::Cli::Placement::Host.new
    "the image" | Dev::Cli::Placement::Image.new(image: image)
  end

  test "a host not provisioned from the image leaves for the standing `lifecycle.runner` first, the enrolled runner only otherwise" do
    Given "a bare host (no marker), a standing preference and an enrolled runner online"
    placement = Dev::Cli::Placement::Image.new(image: image)

    When
    dispatch = resolver(standing: "ue-engine-hosted", enrolled_online: true).resolve(placement, subject: "cellbound-3d-win64-dev")

    Then
    dispatch.is_a?(Dev::Cli::Dispatch::Remote)
    dispatch.transport.runner == "ue-engine-hosted"
  end

  test "with no standing preference, the repo's enrolled runner carries the verb when GitHub lists it online — under the repo's label" do
    Given
    placement = Dev::Cli::Placement::Image.new(image: image)

    When
    dispatch = resolver(enrolled_online: true).resolve(placement, subject: "cellbound-3d-win64-dev")

    Then
    dispatch.is_a?(Dev::Cli::Dispatch::Remote)
    dispatch.transport.runner == "cellbound-3d"
  end

  test "a host not provisioned from the image, with no runner to go to, leaves for the project's own container of the image — the degenerate runner, last (K9)" do
    Given "a bare host (no marker), nothing standing, nothing enrolled"
    placement = Dev::Cli::Placement::Image.new(image: image)

    When
    dispatch = resolver.resolve(placement, subject: "cellbound-3d-win64-dev")

    Then
    dispatch.is_a?(Dev::Cli::Dispatch::Remote)
    dispatch.transport.is_a?(Dev::Cli::Transport::LocalContainer)
    dispatch.transport.runner == "container"
    dispatch.transport.destination == "in cellbound-3d-linux (container)"
  end

  test "a host provisioned from another image is not this image's host either: its container" do
    Given
    File.write(@marker, image(name: "snappy-linux").marker)

    When
    dispatch = resolver.resolve(Dev::Cli::Placement::Image.new(image: image), subject: "cellbound-3d-win64-dev")

    Then
    dispatch.transport.is_a?(Dev::Cli::Transport::LocalContainer)
    dispatch.transport.destination == "in cellbound-3d-linux (container)"
  end

  test "`--container` forces the container over every host the resolution would have picked: #{what}" do
    Given
    File.write(@marker, marker_text) if marker_text
    placement = Dev::Cli::Placement::Image.new(image: image)

    When
    dispatch = resolver(standing: "standing-pool", enrolled_online: true).resolve(placement, subject: "x", container: true)

    Then
    dispatch.is_a?(Dev::Cli::Dispatch::Remote)
    dispatch.transport.is_a?(Dev::Cli::Transport::LocalContainer)

    Where
    what                                            | marker_text
    "a host provisioned from the image"             | image.marker
    "a bare host with a standing runner and an enrolled one" | nil
  end

  test "`--container` inside a container of the image is already there: native" do
    Given
    File.write(@marker, image.marker)

    Expect
    resolver(inside_container: true).resolve(Dev::Cli::Placement::Image.new(image: image), subject: "x", container: true) ==
      Dev::Cli::Dispatch::Native.new
  end

  test "`--container` inside a container that is not the image's is drift, refused" do
    Given
    File.write(@marker, image(apt: ["libnss3"]).marker)

    When
    resolver(inside_container: true).resolve(Dev::Cli::Placement::Image.new(image: image), subject: "x", container: true)

    Then
    raises Dev::Cli::HostRule::ContainerDriftError
  end

  test "`--container` for a build placed on the host is refused: there is no image to run a container of" do
    When
    resolver.resolve(Dev::Cli::Placement::Host.new, subject: "rspock", container: true)

    Then
    error = raises(Dev::Cli::DispatchResolver::NoContainerForHostError)
    error.message.include?("`rspock` is placed on the host")
  end

  test "`--runner` and `--container` together name two hosts for one verb: refused before anything resolves" do
    When
    resolver.resolve(Dev::Cli::Placement::Image.new(image: image), subject: "x", runner: "win64-pool", container: true)

    Then
    error = raises(Dev::Cli::DispatchResolver::ConflictingDispatchFlagsError)
    error.message.include?("--runner win64-pool and --container")
  end

  test "inside a container that is not the image's, the work is drift, refused as the command runner refuses it" do
    Given "a container made from a drifted recipe of the image"
    File.write(@marker, image(apt: ["libnss3"]).marker)

    When
    resolver(inside_container: true).resolve(Dev::Cli::Placement::Image.new(image: image), subject: "cellbound-3d-win64-dev")

    Then
    raises Dev::Cli::HostRule::ContainerDriftError
  end

  test "a verb inside an Actions job never leaves: #{what} is DispatchFromJobError naming the host and the misprovisioning" do
    Given "a runner that is not the build's environment"
    placement = Dev::Cli::Placement::Image.new(image: image)

    When
    resolver(standing: standing, inside_job: true).resolve(placement, subject: "cellbound-3d-win64-dev", runner: forced, container: forced_container)

    Then
    error = raises(Dev::Cli::DispatchResolver::DispatchFromJobError)
    error.message.include?("`cellbound-3d-win64-dev` would leave this Actions job for #{to}")
    error.message.include?("a job never dispatches a job")

    Where
    what                      | standing           | forced       | forced_container | to
    "the resolved runner"     | "ue-engine-hosted" | nil          | false            | "runner `ue-engine-hosted`"
    "a forced `--runner`"     | "ue-engine-hosted" | "win64-pool" | false            | "runner `win64-pool`"
    "the resolved container"  | nil                | nil          | false            | "a container of cellbound-3d-linux"
    "a forced `--container`"  | nil                | nil          | true             | "a container of cellbound-3d-linux"
  end

  test "inside an Actions job that is the build's environment, the verb is native as anywhere else" do
    Given
    File.write(@marker, image.marker)

    Expect
    resolver(inside_job: true).resolve(Dev::Cli::Placement::Image.new(image: image), subject: "x") == Dev::Cli::Dispatch::Native.new
  end
end

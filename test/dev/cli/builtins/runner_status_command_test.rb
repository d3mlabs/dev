# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/builtins/runner_status_command"
require "dev/deps/dependency"
require "dev/deps/lockfile"
require "dev/environment_image"
require "dev/lifecycle/build_pattern"
require "dev/lifecycle/channel"
require "dev/lifecycle/project_version"
require "dev/lifecycle/publisher_spec"
require "dev/lifecycle/target"
require "dev/stream"
require "dev/runner_role"
require "dev/runner_role_aliases"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Cli::Builtins::RunnerStatusCommandTest < Minitest::Test
  include SorbetHelper

  # A dev.yml role of a checkout's own: repo-scoped, no group.
  FARM = Dev::RunnerRole::Declaration.new(name: "ue-farm", labels: %w[ue gpu])
  # The same role grouped and pinned to the project's own workflow, its jobs as ue-builder.
  GROUPED_FARM = Dev::RunnerRole::Declaration.new(
    name: "ue-farm", labels: %w[ue gpu], group: "ue-farm", workflows: [".github/workflows/build.yml"], job_identity: "ue-builder",
  )
  # A project deployed through gh: the channel a declared role's slots follow.
  GH_CHANNELS = {
    "gh" => Dev::Lifecycle::Channel.new(
      name: "gh",
      accepts: [Dev::Lifecycle::BuildPattern.new(target: Dev::Lifecycle::Target.new(name: "ai-flow"))],
      publisher: Dev::Lifecycle::PublisherSpec::Integration.new(name: "gh"),
    ),
  }.freeze

  test "traits: lifecycle section, guarded like any read command, never stamps" do
    Given "the builtin"
    command = Dev::Cli::Builtins::RunnerStatusCommand.new

    Expect
    command.category == Dev::Cli::Command::Category::Environment
    command.staleness_exempt? == false
    command.stamps? == false
    command.flags.map(&:name) == ["--check"]
  end

  # dev#571: a job runs `--check` after every `dev up`; the inspector's
  # check is the host's posture alone and raises on drift (the boundary
  # exits 1).
  test "--check runs the inspector's check, not its report" do
    Given "a status factory handing back an inspector that expects check"
    status = typed_mock(Dev::RunnerStatus)
    status.expects(:check).once
    status.expects(:report).never
    command = Dev::Cli::Builtins::RunnerStatusCommand.new(runner_status_factory: ->(_container, _root, _declarations, _channels, _ui) { status })

    When "running status --check with no project"
    command.call(args: Dev::Cli::ParsedArgs.new(words: ["--check"], switches: ["--check"]), context: Dev::Cli::ExecutionContext.new(ui: typed_mock(Dev::Ui)))

    Then
    true
  end

  test "a PostureDriftError from --check reaches the boundary unwrapped" do
    Given "an inspector whose check finds drift"
    status = typed_mock(Dev::RunnerStatus)
    status.expects(:check).raises(Dev::RunnerStatus::PostureDriftError, "host posture: 1 of 2 facts drifted")
    command = Dev::Cli::Builtins::RunnerStatusCommand.new(runner_status_factory: ->(_container, _root, _declarations, _channels, _ui) { status })

    When
    error = assert_raises(Dev::RunnerStatus::PostureDriftError) do
      command.call(args: Dev::Cli::ParsedArgs.new(words: ["--check"], switches: ["--check"]), context: Dev::Cli::ExecutionContext.new(ui: typed_mock(Dev::Ui)))
    end

    Then
    error.message == "host posture: 1 of 2 facts drifted"
  end

  test "status wires the inspector with the container fact, the checkout's declared roles and channels, and the context's Ui (plans#52, dev#657, dev#658)" do
    Given "a status factory recording its wiring; a checkout declaring ue-farm and a gh channel"
    seen = []
    status = typed_mock(Dev::RunnerStatus)
    status.expects(:report).once
    command = Dev::Cli::Builtins::RunnerStatusCommand.new(
      runner_status_factory: ->(container_required, project_root, declarations, channels, ui) {
        seen << [container_required, project_root, declarations, channels, ui]
        status
      },
    )
    root = image_checkout
    ui = typed_mock(Dev::Ui)

    When "running status inside a container repo (its lock pins an image)"
    command.call(args: no_args, context: build_context(root: root, ui: ui, runner_roles: { "ue-farm" => FARM }, channels: GH_CHANNELS))

    Then "the container fact, the checkout, its declarations, its channels and the Ui reach the inspector"
    seen == [[true, Pathname.new(root), { "ue-farm" => FARM }, GH_CHANNELS, ui]]
  end

  test "status works projectless (the machine view needs no checkout)" do
    Given "a status factory"
    status = typed_mock(Dev::RunnerStatus)
    status.expects(:report).once
    command = Dev::Cli::Builtins::RunnerStatusCommand.new(runner_status_factory: ->(_container, _root, _declarations, _channels, _ui) { status })

    When "running status with no project"
    command.call(args: no_args, context: Dev::Cli::ExecutionContext.new(ui: typed_mock(Dev::Ui)))

    Then
    true
  end

  test "the default factory builds the real inspector" do
    Given "a command with its default wiring, the construction boundary intercepted"
    status = typed_mock(Dev::RunnerStatus)
    status.expects(:report).once
    ui = typed_mock(Dev::Ui)
    Dev::RunnerStatus.expects(:new).with(container_required: false, pins: [], repo: nil, roles: Dev::RunnerRoleAliases::ALL, ui: ui).returns(status)
    command = Dev::Cli::Builtins::RunnerStatusCommand.new

    When "running status outside a checkout"
    command.call(args: no_args, context: Dev::Cli::ExecutionContext.new(ui: ui))

    Then "the expectation on the construction boundary holds: no lock, no repo, the aliases alone as roles"
    true
  end

  test "in a checkout the default factory hands the inspector the checkout's repo — or nil when gh cannot name it — and its roles bound to it" do
    Given "a checkout at 2.1.0 declaring a grouped ue-farm, with an empty lock, gh answering (or not)"
    root = Pathname.new(Dir.mktmpdir)
    File.write(root.join(Dev::Lifecycle::ProjectVersion::FILE_NAME), "2.1.0\n")
    status = typed_mock(Dev::RunnerStatus)
    status.expects(:report).once
    Dev::RunnerSetup.expects(:current_repo).then.raises(Dev::RunnerSetup::Error, "could not resolve the repo via gh: offline") if repo.nil?
    Dev::RunnerSetup.expects(:current_repo).returns(repo) unless repo.nil?
    ui = typed_mock(Dev::Ui)
    Dev::RunnerStatus.expects(:new).with(container_required: false, pins: [], repo: repo, roles: roles, ui: ui).returns(status)
    command = Dev::Cli::Builtins::RunnerStatusCommand.new

    When
    command.call(args: no_args, context: build_context(root: root.to_s, ui: ui, runner_roles: { "ue-farm" => GROUPED_FARM }))

    Then "with a repo, the declaration binds to it at the checkout's series beside the aliases; without one, the aliases alone"
    true

    Where
    repo           | roles
    "d3mlabs/dev"  | Dev::RunnerRoleAliases::ALL.merge("ue-farm" => GROUPED_FARM.bind(repo: "d3mlabs/dev", version: "2.1.0"))
    nil            | Dev::RunnerRoleAliases::ALL
  end

  test "roles_at_hand binds the checkout's declarations to its repo at v<major>, the aliases beside them" do
    Given "a checkout at 3.4.1"
    root = Pathname.new(Dir.mktmpdir)
    File.write(root.join(Dev::Lifecycle::ProjectVersion::FILE_NAME), "3.4.1\n")

    When
    roles = Dev::Cli::Builtins::RunnerStatusCommand.roles_at_hand({ "ue-farm" => GROUPED_FARM }, project_root: root, repo: "d3mlabs/cellbound-3d")

    Then
    roles.keys == ["agent", "orchestrator", "ue-farm"]
    roles.fetch("ue-farm").group.workflows == ["d3mlabs/cellbound-3d/.github/workflows/build.yml@refs/tags/v3"]
    roles.fetch("ue-farm").job_identity == "ue-builder"
  end

  test "roles_at_hand anchors a declared role to the checkout's stream when it deploys through gh (dev#658)" do
    Given "a checkout at 3.4.1 with a gh channel"
    root = Pathname.new(Dir.mktmpdir)
    File.write(root.join(Dev::Lifecycle::ProjectVersion::FILE_NAME), "3.4.1\n")

    When
    roles = Dev::Cli::Builtins::RunnerStatusCommand.roles_at_hand(
      { "ue-farm" => FARM }, project_root: root, repo: "d3mlabs/ai-flow", channels: GH_CHANNELS,
    )

    Then "the declared role follows d3mlabs/ai-flow@gh ~> 3; the aliases follow nothing"
    roles.fetch("ue-farm").stream == Dev::Stream.parse("d3mlabs/ai-flow@gh ~> 3")
    roles.fetch("agent").stream.nil?
  end

  test "roles_at_hand outside a checkout, or in one gh cannot name, is the aliases alone: a declaration's pins are spelled with the repo" do
    Expect
    Dev::Cli::Builtins::RunnerStatusCommand.roles_at_hand({ "ue-farm" => GROUPED_FARM }, project_root: nil, repo: nil) == Dev::RunnerRoleAliases::ALL
    Dev::Cli::Builtins::RunnerStatusCommand.roles_at_hand({ "ue-farm" => GROUPED_FARM }, project_root: Pathname.new(Dir.mktmpdir), repo: nil) ==
      Dev::RunnerRoleAliases::ALL
  end

  private

  def build_context(root: "/tmp/runner-status-test", ui: typed_mock(Dev::Ui), runner_roles: {}, channels: {})
    Dev::Cli::ExecutionContext.new(
      ui: ui,
      project: Dev::Cli::ProjectContext.new(name: "Cellbound3D", root: Pathname.new(root), runner_roles: runner_roles, channels: channels),
    )
  end

  # A checkout whose lock pins one image: the container fact, as the
  # commands read it (ProjectImages#containerized?).
  def image_checkout
    root = Dir.mktmpdir("runner-image-checkout")
    pin = Dev::Deps::Dependency.new(
      name: "snappy-linux", integration: :image, group: :app, version: "ue5.8-3", hash: "SHA256=#{"a" * 64}",
      metadata: {
        "from" => "ghcr.io/d3mlabs/unreal-engine-build-base", "platform" => "linux/amd64",
        "platforms" => ["linux/amd64"], "registry" => "ghcr.io/d3mlabs", "apt" => [],
      },
    )
    Dev::Deps::Lockfile.new(dir: Pathname(root)).lock(Dev::EnvironmentImage.stamp([pin]))
    root
  end
end

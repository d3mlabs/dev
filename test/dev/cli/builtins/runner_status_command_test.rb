# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/builtins/runner_status_command"
require "dev/deps/dependency"
require "dev/deps/lockfile"
require "dev/environment_image"
require "dev/lifecycle/project_version"
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
  # A checkout's reference to ai-flow's agent role (dev#701), the lock pin
  # it is read at, and the role the declaring repo's dev.yml gives it.
  AGENT_REFERENCE = Dev::RunnerRole::Reference.new(name: "agent", declaring_repo: "d3mlabs/ai-flow")
  AI_FLOW_PIN = Dev::Deps::Dependency.new(
    name: "ai-flow", integration: :gh, group: :app, version: "2.4.1", hash: "SHA256=#{"b" * 64}", source: "c0ffee", metadata: { "repo" => "d3mlabs/ai-flow" },
  )
  REFERENCED_AGENT = Dev::RunnerRole::Declaration.new(
    name: "agent", labels: Dev::RunnerRoleAliases::AGENT.labels, group: "ai-flow", workflows: [".github/workflows/ai-commands.yml"], job_identity: "ai-agent",
  ).as_referenced
  # roles_at_hand's resolver where no reference is at hand.
  NO_REFERENCES = ->(reference) { raise "no reference expected, got #{reference.name}" }

  # The referenced-role loader's seam: answers each reference with the
  # role a test canned for it and records the reference and lock it was
  # handed. gh is never reached.
  class FakeReferencedRoleLoader < Dev::Cli::ReferencedRoleLoader
    attr_reader :loads

    def initialize(answers)
      super(executor: nil)
      @answers = answers
      @loads = []
    end

    def load(reference, pins)
      @loads << [reference, pins]
      @answers.fetch(reference)
    end
  end

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
    command = Dev::Cli::Builtins::RunnerStatusCommand.new(runner_status_factory: ->(_container, _root, _declarations, _ui) { status })

    When "running status --check with no project"
    command.call(args: Dev::Cli::ParsedArgs.new(words: ["--check"], switches: ["--check"]), context: Dev::Cli::ExecutionContext.new(ui: typed_mock(Dev::Ui)))

    Then
    true
  end

  test "a PostureDriftError from --check reaches the boundary unwrapped" do
    Given "an inspector whose check finds drift"
    status = typed_mock(Dev::RunnerStatus)
    status.expects(:check).raises(Dev::RunnerStatus::PostureDriftError, "host posture: 1 of 2 facts drifted")
    command = Dev::Cli::Builtins::RunnerStatusCommand.new(runner_status_factory: ->(_container, _root, _declarations, _ui) { status })

    When
    error = assert_raises(Dev::RunnerStatus::PostureDriftError) do
      command.call(args: Dev::Cli::ParsedArgs.new(words: ["--check"], switches: ["--check"]), context: Dev::Cli::ExecutionContext.new(ui: typed_mock(Dev::Ui)))
    end

    Then
    error.message == "host posture: 1 of 2 facts drifted"
  end

  test "status wires the inspector with the container fact, the checkout's declared roles and the context's Ui (plans#52, dev#657)" do
    Given "a status factory recording its wiring; a checkout declaring ue-farm"
    seen = []
    status = typed_mock(Dev::RunnerStatus)
    status.expects(:report).once
    command = Dev::Cli::Builtins::RunnerStatusCommand.new(
      runner_status_factory: ->(container_required, project_root, declarations, ui) {
        seen << [container_required, project_root, declarations, ui]
        status
      },
    )
    root = image_checkout
    ui = typed_mock(Dev::Ui)

    When "running status inside a container repo (its lock pins an image)"
    command.call(args: no_args, context: build_context(root: root, ui: ui, runner_roles: { "ue-farm" => FARM }))

    Then "the container fact, the checkout, its declarations and the Ui reach the inspector"
    seen == [[true, Pathname.new(root), { "ue-farm" => FARM }, ui]]
  end

  test "status works projectless (the machine view needs no checkout)" do
    Given "a status factory"
    status = typed_mock(Dev::RunnerStatus)
    status.expects(:report).once
    command = Dev::Cli::Builtins::RunnerStatusCommand.new(runner_status_factory: ->(_container, _root, _declarations, _ui) { status })

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
    roles = Dev::Cli::Builtins::RunnerStatusCommand.roles_at_hand(
      { "ue-farm" => GROUPED_FARM }, project_root: root, repo: "d3mlabs/cellbound-3d", resolve: NO_REFERENCES,
    )

    Then
    roles.keys == ["agent", "orchestrator", "ue-farm"]
    roles.fetch("ue-farm").group.workflows == ["d3mlabs/cellbound-3d/.github/workflows/build.yml@refs/tags/v3"]
    roles.fetch("ue-farm").job_identity == "ue-builder"
  end

  test "roles_at_hand resolves a referenced role as the caller says, in place of the alias of its name, the declarations bound beside it (dev#701)" do
    Given "a checkout at 0.1.0 referencing ai-flow's agent and declaring its own farm"
    root = Pathname.new(Dir.mktmpdir)
    File.write(root.join(Dev::Lifecycle::ProjectVersion::FILE_NAME), "0.1.0\n")
    resolved = []
    resolve = ->(reference) {
      resolved << reference
      REFERENCED_AGENT
    }

    When
    roles = Dev::Cli::Builtins::RunnerStatusCommand.roles_at_hand(
      { "agent" => AGENT_REFERENCE, "ue-farm" => FARM }, project_root: root, repo: "d3mlabs/cellbound-3d", resolve: resolve,
    )

    Then
    resolved == [AGENT_REFERENCE]
    roles.keys == ["agent", "orchestrator", "ue-farm"]
    roles.fetch("agent") == REFERENCED_AGENT
    roles.fetch("ue-farm") == FARM.bind(repo: "d3mlabs/cellbound-3d", version: "0.1.0")
  end

  test "in a checkout referencing a role, the default factory reads it through the loader against the checkout's lock" do
    Given "a checkout pinning ai-flow at 2.4.1 and referencing its agent role"
    root = Pathname.new(Dir.mktmpdir)
    File.write(root.join(Dev::Lifecycle::ProjectVersion::FILE_NAME), "0.1.0\n")
    Dev::Deps::Lockfile.new(dir: root).lock([AI_FLOW_PIN])
    pins = Dev::Deps::Lockfile.new(dir: root).read
    loader = FakeReferencedRoleLoader.new(AGENT_REFERENCE => REFERENCED_AGENT)
    status = typed_mock(Dev::RunnerStatus)
    status.expects(:report).once
    Dev::RunnerSetup.expects(:current_repo).returns("d3mlabs/cellbound-3d")
    ui = typed_mock(Dev::Ui)
    Dev::RunnerStatus.expects(:new).with(
      container_required: false, pins: pins, repo: "d3mlabs/cellbound-3d", roles: Dev::RunnerRoleAliases::ALL.merge("agent" => REFERENCED_AGENT), ui: ui,
    ).returns(status)
    command = Dev::Cli::Builtins::RunnerStatusCommand.new(referenced_role_loader: loader)

    When
    command.call(args: no_args, context: build_context(root: root.to_s, ui: ui, runner_roles: { "agent" => AGENT_REFERENCE }))

    Then "the lane is reported under the referenced role; the loader saw the reference and the lock"
    pins.length == 1
    loader.loads == [[AGENT_REFERENCE, pins]]
  end

  test "--check leaves a referenced role out: GitHub is not asked, so the declaring repo is not read" do
    Given "a factory recording the entries it is handed; a loader that must not be asked"
    seen = []
    status = typed_mock(Dev::RunnerStatus)
    status.expects(:check).once
    loader = FakeReferencedRoleLoader.new({})
    command = Dev::Cli::Builtins::RunnerStatusCommand.new(
      referenced_role_loader: loader,
      runner_status_factory: ->(_container, _root, entries, _ui) {
        seen << entries
        status
      },
    )

    When
    command.call(
      args: Dev::Cli::ParsedArgs.new(words: ["--check"], switches: ["--check"]),
      context: build_context(runner_roles: { "agent" => AGENT_REFERENCE, "ue-farm" => FARM }),
    )

    Then "the declaration alone reaches the inspector"
    seen == [{ "ue-farm" => FARM }]
    loader.loads == []
  end

  test "roles_at_hand outside a checkout, or in one gh cannot name, is the aliases alone: a declaration's pins are spelled with the repo" do
    Expect
    Dev::Cli::Builtins::RunnerStatusCommand.roles_at_hand({ "ue-farm" => GROUPED_FARM }, project_root: nil, repo: nil, resolve: NO_REFERENCES) ==
      Dev::RunnerRoleAliases::ALL
    Dev::Cli::Builtins::RunnerStatusCommand.roles_at_hand(
      { "ue-farm" => GROUPED_FARM, "agent" => AGENT_REFERENCE }, project_root: Pathname.new(Dir.mktmpdir), repo: nil, resolve: NO_REFERENCES,
    ) == Dev::RunnerRoleAliases::ALL
  end

  private

  def build_context(root: "/tmp/runner-status-test", ui: typed_mock(Dev::Ui), runner_roles: {})
    Dev::Cli::ExecutionContext.new(
      ui: ui,
      project: Dev::Cli::ProjectContext.new(name: "Cellbound3D", root: Pathname.new(root), runner_roles: runner_roles),
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

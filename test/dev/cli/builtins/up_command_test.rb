# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/builtins/container_up_command"
require "dev/cli/builtins/install_deps_command"
require "dev/cli/builtins/up_command"
require "dev/deps/dependency"
require "dev/deps/lockfile"
require "dev/environment_image"
require "dev/host_environment"
require "dev/cli/host_rule"
require "dev/linux_data_root_provisioner"
require "fileutils"
require "pathname"
require "stringio"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Cli::Builtins::UpCommandTest < Minitest::Test
  include SorbetHelper

  # The install body's vocabulary: `up` composes its own flags from it, so a
  # test that parses `up`'s args states it as the mock's answer to `flags`.
  INSTALL_DEPS_FLAGS = [
    Dev::Cli::Flag.new(Dev::Cli::Builtins::InstallDepsCommand::GROUP_FLAG, takes_value: true),
    Dev::Cli::Flag.new(Dev::Cli::Builtins::InstallDepsCommand::PINNED_TAPS_FLAG),
  ].freeze

  test "traits: staleness-exempt (it IS the remediation) and stamps on success" do
    Given "the builtin"
    command = Dev::Cli::Builtins::UpCommand.new(
      install_deps_command: install_deps_mock, host_service: typed_mock(Dev::HostService), service_dependencies: [], data_root_provisioner: nil,
    )

    Expect "the declarative traits"
    command.staleness_exempt? == true
    command.stamps? == true
    !command.hidden?
  end

  test "call ensures the dev cd shell hook and composes the dev deps install body" do
    Given "an up command over both collaborators"
    install_deps = install_deps_mock
    host_service = typed_mock(Dev::HostService)
    command = Dev::Cli::Builtins::UpCommand.new(install_deps_command: install_deps, host_service: host_service, data_root_provisioner: nil)
    context = build_context

    When "running up"
    command.call(args: parsed_args(command, ["--pinned-taps"]), context: context)

    Then "the hook is installed and the install body received the same args and context"
    _ * install_deps.flags >> INSTALL_DEPS_FLAGS
    _ * host_service.converge_tooling >> Dev::HostService::TOOLING_CONVERGED
    _ * host_service.sync_skills
    1 * host_service.install_rc_hook
    1 * install_deps.call(args: parsed_args(command, ["--pinned-taps"]), context: context)
  end

  test "call converges the host tooling and links shipped skills as its host half" do
    Given "an up command over a host service"
    host_service = typed_mock(Dev::HostService)
    install_deps = install_deps_mock
    command = Dev::Cli::Builtins::UpCommand.new(install_deps_command: install_deps, host_service: host_service, data_root_provisioner: nil)

    When "running up"
    command.call(args: no_args, context: build_context)

    Then "the host service converged the tooling and linked the skills"
    _ * host_service.install_rc_hook
    _ * install_deps.call
    1 * host_service.converge_tooling >> Dev::HostService::TOOLING_CONVERGED
    1 * host_service.sync_skills(project_root: nil)
  end

  test "call makes the Linux data root exist as part of the host half, before the install" do
    Given "a host whose data root step applies"
    install_deps = install_deps_mock
    host_service = typed_mock(Dev::HostService)
    provisioner = typed_mock(Dev::LinuxDataRootProvisioner)
    order = []
    # call order: the data root must exist at its final path before the install lands in it
    provisioner.expects(:provision!).once.with { |ui:| order.push(:root).any? && ui.is_a?(Dev::Ui) }
    install_deps.expects(:call).once.with { |**| order.push(:install).any? }
    command = Dev::Cli::Builtins::UpCommand.new(
      install_deps_command: install_deps, host_service: host_service, data_root_provisioner: provisioner,
    )

    When
    command.call(args: no_args, context: build_context)

    Then "the root exists before anything installs into it"
    _ * host_service.converge_tooling >> Dev::HostService::TOOLING_CONVERGED
    _ * host_service.install_rc_hook
    _ * host_service.sync_skills
    order == [:root, :install]
  end

  test "a projectless up still makes the data root: it is the machine's, not the project's" do
    Given
    host_service = typed_mock(Dev::HostService)
    provisioner = typed_mock(Dev::LinuxDataRootProvisioner)
    command = Dev::Cli::Builtins::UpCommand.new(
      install_deps_command: install_deps_mock, host_service: host_service, data_root_provisioner: provisioner,
    )

    When
    capture_stdout { command.call(args: no_args, context: Dev::Cli::ExecutionContext.new(ui: typed_mock(Dev::Ui))) }

    Then
    _ * host_service.converge_tooling >> Dev::HostService::TOOLING_CONVERGED
    _ * host_service.install_rc_hook
    _ * host_service.sync_skills
    _ * host_service.sync_learnings
    1 * provisioner.provision!
  end

  test "call without a project converges the host half, syncs org learnings, and skips provisioning" do
    Given "a projectless context and a host service expecting only host work"
    host_service = typed_mock(Dev::HostService)
    install_deps = install_deps_mock
    command = Dev::Cli::Builtins::UpCommand.new(install_deps_command: install_deps, host_service: host_service, data_root_provisioner: nil)
    context = Dev::Cli::ExecutionContext.new(ui: typed_mock(Dev::Ui))

    When "running up outside any project"
    stdout = capture_stdout { command.call(args: no_args, context: context) }

    Then "deps install never runs, and the bootstrap message points at projects"
    1 * host_service.converge_tooling >> Dev::HostService::TOOLING_CONVERGED
    1 * host_service.install_rc_hook
    1 * host_service.sync_skills(project_root: nil)
    1 * host_service.sync_learnings(project_root: nil)
    0 * install_deps.call(args: anything, context: anything)
    stdout.include?("dev: host layer converged.\n")
    stdout.include?("no dev.yml here — run dev up inside a project to provision it too")
  end

  # dev#622: the operator's projectless `dev up` on the box read "host
  # layer converged" while the brew layer — dev's self-update included —
  # had been skipped for the runner user's prefix; `dev --version` stayed
  # put. The summary is the one place the skip is told (in a checkout it
  # stays silent: every `dev up` there would nag), so it names the owner
  # and the by-hand converge.
  test "a projectless up whose brew layer was skipped says so, naming the prefix owner — #{what}" do
    Given "a host service whose tooling converge reports the skip"
    host_service = typed_mock(Dev::HostService)
    command = Dev::Cli::Builtins::UpCommand.new(install_deps_command: install_deps_mock, host_service: host_service, data_root_provisioner: nil)

    When "running up outside any project"
    stdout = capture_stdout { command.call(args: no_args, context: Dev::Cli::ExecutionContext.new(ui: typed_mock(Dev::Ui))) }

    Then "the summary carries the skip and the remedy, and still points at projects"
    _ * host_service.converge_tooling >> Dev::HostService::ToolingOutcome.new(skipped: true, prefix_owner: owner)
    _ * host_service.install_rc_hook
    _ * host_service.sync_skills
    _ * host_service.sync_learnings
    stdout.include?(summary)
    !stdout.include?("dev: host layer converged.\n")
    stdout.include?("no dev.yml here — run dev up inside a project to provision it too")

    Where
    what            | owner    | summary
    "owner known"   | "runner" | "dev: host layer converged — brew tooling is runner's and was skipped (jobs converge it; by hand: sudo -iu runner dev up)"
    "owner unknown" | nil      | "dev: host layer converged — brew tooling is another user's and was skipped (jobs converge it; by hand: dev up as the brew prefix's owner)"
  end

  test "call brings the service dependencies up, in order, after the deps install they may depend on — through the port, not the CLI" do
    Given "two service dependencies; deps install and both bring-ups observed in order"
    order = sequence("deps, then services in order")
    install_deps = install_deps_mock
    host_service = typed_mock(Dev::HostService)
    context = build_context
    first = typed_mock(Dev::Cli::Builtins::ContainerUpCommand)
    second = typed_mock(Dev::Cli::Builtins::ContainerUpCommand)
    # call order: a service's bring-up may need the locked deps on disk, and a later service may need an earlier one
    install_deps.expects(:call).once.in_sequence(order)
    first.expects(:up).with(project: context.project).once.in_sequence(order)
    second.expects(:up).with(project: context.project).once.in_sequence(order)
    command = Dev::Cli::Builtins::UpCommand.new(
      install_deps_command: install_deps, host_service: host_service, service_dependencies: [first, second], data_root_provisioner: nil,
    )

    When "running up"
    command.call(args: no_args, context: context)

    Then "asserted on the mocks: the services are ready before the first command that needs them"
    _ * host_service.converge_tooling >> Dev::HostService::TOOLING_CONVERGED
    _ * host_service.install_rc_hook
    _ * host_service.sync_skills
    0 * first.call
  end

  test "inside the container, call is the deps install alone: no host converge or service bring-up" do
    Given "an inside up command whose host service and service dependency must stay untouched"
    host_service = typed_mock(Dev::HostService)
    install_deps = install_deps_mock
    service = typed_mock(Dev::Cli::Builtins::ContainerUpCommand)
    context = build_context
    command = Dev::Cli::Builtins::UpCommand.new(
      install_deps_command: install_deps, host_service: host_service,
      service_dependencies: [service], inside_container: true, data_root_provisioner: nil,
    )

    When "running up inside"
    command.call(args: parsed_args(command, ["--group", "app"]), context: context)

    Then "only the install body ran, with the user's args"
    _ * install_deps.flags >> INSTALL_DEPS_FLAGS
    1 * install_deps.call(args: parsed_args(command, ["--group", "app"]), context: context)
    0 * host_service.converge_tooling
    0 * host_service.install_rc_hook
    0 * host_service.sync_skills
    0 * service.up(project: anything)
  end

  test "inside a container of the lock's image, call installs" do
    Given
    root, current, _older = inside_fixture
    (root / "marker").write(current.marker)
    install_deps = install_deps_mock
    command = inside_up_command(install_deps, root)
    context = inside_context(root)

    When
    command.call(args: no_args, context: context)

    Then
    1 * install_deps.call(args: anything, context: context)

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "inside a container made from an older recipe, call refuses before installing: the container cannot replace itself" do
    Given
    root, _current, older = inside_fixture
    (root / "marker").write(older.marker)
    install_deps = install_deps_mock
    command = inside_up_command(install_deps, root)

    When
    command.call(args: no_args, context: inside_context(root))

    Then
    0 * install_deps.call
    error = raises Dev::Cli::HostRule::ContainerDriftError
    error.message.include?("this container is snappy-linux@#{older.short_digest}")
    error.message.include?("re-create it from the host: `dev container reset && dev up`")

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "inside the container without a project, call explains there is nothing to provision" do
    Given "an inside up command and a projectless context"
    host_service = typed_mock(Dev::HostService)
    install_deps = install_deps_mock
    command = Dev::Cli::Builtins::UpCommand.new(
      install_deps_command: install_deps, host_service: host_service, inside_container: true, data_root_provisioner: nil,
    )
    context = Dev::Cli::ExecutionContext.new(ui: typed_mock(Dev::Ui))

    When "running up"
    stdout = capture_stdout { command.call(args: no_args, context: context) }

    Then "neither half runs and the message says why"
    0 * install_deps.call(args: anything, context: anything)
    0 * host_service.converge_tooling
    stdout.include?("dev: inside a container with no dev.yml — nothing to provision.")
  end

  test "--no-cache runs the install and the services' cold bring-up inside a throwaway data root, host layer untouched" do
    Given "a warm data root in a scratch dir, and collaborators recording the data root they ran under"
    warm = Dir.mktmpdir("up-no-cache-warm-")
    original = ENV.fetch("DEV_DATA_ROOT", nil)
    ENV["DEV_DATA_ROOT"] = warm
    # Typed fakes: what matters is the data root in force at the moment each
    # half runs, which only the call itself can read.
    installs = []
    install_deps = install_deps_mock
    install_deps.define_singleton_method(:call) { |args:, context:| installs << [args, ENV.fetch("DEV_DATA_ROOT"), context.project] }
    cold_ups = []
    service = typed_mock(Dev::Cli::Builtins::ContainerUpCommand)
    service.define_singleton_method(:cold_up) { |project:| cold_ups << [ENV.fetch("DEV_DATA_ROOT"), project] }
    host_service = typed_mock(Dev::HostService)
    context = build_context
    command = Dev::Cli::Builtins::UpCommand.new(
      install_deps_command: install_deps, host_service: host_service, service_dependencies: [service], data_root_provisioner: nil,
    )

    When "running dev up --no-cache --group app"
    command.call(args: parsed_args(command, ["--no-cache", "--group", "app"]), context: context)

    Then "both halves ran under one throwaway sibling of the warm root, which is gone and restored afterwards"
    _ * install_deps.flags >> INSTALL_DEPS_FLAGS
    0 * service.up
    installs.length == 1
    cold_ups.length == 1
    install_args, install_root, installed_project = installs.fetch(0)
    cold_root, cold_project = cold_ups.fetch(0)
    install_args == parsed_args(command, ["--no-cache", "--group", "app"])
    installed_project == context.project
    cold_project == context.project
    install_root.start_with?("#{warm}-cold-")
    cold_root == install_root
    !File.exist?(cold_root)
    ENV.fetch("DEV_DATA_ROOT") == warm
    0 * host_service.converge_tooling
    0 * host_service.install_rc_hook
    0 * host_service.sync_skills

    Cleanup
    if original.nil?
      ENV.delete("DEV_DATA_ROOT")
    else
      ENV["DEV_DATA_ROOT"] = original
    end
    FileUtils.rm_rf(warm)
  end

  test "--no-cache outside a project explains it needs one and provisions nothing" do
    Given "a projectless context"
    install_deps = install_deps_mock
    host_service = typed_mock(Dev::HostService)
    command = Dev::Cli::Builtins::UpCommand.new(install_deps_command: install_deps, host_service: host_service, data_root_provisioner: nil)
    context = Dev::Cli::ExecutionContext.new(ui: typed_mock(Dev::Ui))

    When "running dev up --no-cache"
    stdout = capture_stdout { command.call(args: parsed_args(command, ["--no-cache"]), context: context) }

    Then "nothing ran and the message says why"
    _ * install_deps.flags >> INSTALL_DEPS_FLAGS
    0 * install_deps.call(args: anything, context: anything)
    0 * host_service.converge_tooling
    stdout.include?("dev up --no-cache needs a project")
  end

  test "inside the container, --no-cache is a host-side topology: it is reported and the plain install runs" do
    Given "an inside up command"
    install_deps = install_deps_mock
    command = Dev::Cli::Builtins::UpCommand.new(
      install_deps_command: install_deps, host_service: typed_mock(Dev::HostService), inside_container: true, data_root_provisioner: nil,
    )
    context = build_context

    When "running dev up --no-cache inside"
    stdout = capture_stdout { command.call(args: parsed_args(command, ["--no-cache"]), context: context) }

    Then "the install ran with the same args (the flag is not one it reads) and the output explains"
    _ * install_deps.flags >> INSTALL_DEPS_FLAGS
    1 * install_deps.call(args: parsed_args(command, ["--no-cache"]), context: context)
    stdout.include?("--no-cache runs from the host")
  end

  test "call with no service dependencies is the deps install alone" do
    Given "a plain project"
    install_deps = install_deps_mock
    host_service = typed_mock(Dev::HostService)
    command = Dev::Cli::Builtins::UpCommand.new(
      install_deps_command: install_deps, host_service: host_service, service_dependencies: [], data_root_provisioner: nil,
    )

    When "running up"
    command.call(args: no_args, context: build_context)

    Then
    _ * host_service.converge_tooling >> Dev::HostService::TOOLING_CONVERGED
    _ * host_service.install_rc_hook
    _ * host_service.sync_skills
    1 * install_deps.call
  end

  private

  def install_deps_mock
    typed_mock(Dev::Cli::Builtins::InstallDepsCommand)
  end

  def capture_stdout
    old_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old_stdout
  end

  # A checkout pinning one image; returns [root, the lock's image, an older recipe of it].
  def inside_fixture
    root = Pathname(Dir.mktmpdir("up-inside"))
    pin = Dev::Deps::Dependency.new(
      name: "snappy-linux", integration: :image, group: :app, version: "ue5.8-3", hash: "SHA256=#{"a" * 64}",
      metadata: {
        "from" => "ghcr.io/d3mlabs/unreal-engine-build-base", "platform" => "linux/amd64",
        "platforms" => ["linux/amd64"], "registry" => "ghcr.io/d3mlabs", "apt" => [],
      },
    )
    Dev::Deps::Lockfile.new(dir: root).lock(Dev::EnvironmentImage.stamp([pin]))
    current = Dev::EnvironmentImage.from_pin(Dev::Deps::Lockfile.new(dir: root).read.first)
    older = Dev::EnvironmentImage.new(
      name: current.name, from: current.from, from_digest: current.from_digest, platform: current.platform,
      apt: ["libnss3"], registry: current.registry,
    )
    [root, current, older]
  end

  def inside_up_command(install_deps, root)
    host_rule = Dev::Cli::HostRule.new(
      host_environment: Dev::HostEnvironment.new(path: (root / "marker").to_s),
    )
    Dev::Cli::Builtins::UpCommand.new(
      install_deps_command: install_deps, host_service: typed_mock(Dev::HostService), inside_container: true, host_rule: host_rule, data_root_provisioner: nil,
    )
  end

  def inside_context(root)
    Dev::Cli::ExecutionContext.new(ui: typed_mock(Dev::Ui), project: Dev::Cli::ProjectContext.new(name: "snappy", root: root))
  end

  def build_context
    Dev::Cli::ExecutionContext.new(
      ui: typed_mock(Dev::Ui),
      project: Dev::Cli::ProjectContext.new(name: "TestProject", root: Pathname.new("/tmp/up-test")),
    )
  end
end

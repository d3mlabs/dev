# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/container_up_command"
require "dev/builtins/install_deps_command"
require "dev/builtins/up_command"
require "dev/build_container_config"
require "dev/credentials"
require "dev/deps/dependency"
require "dev/deps/lockfile"
require "dev/environment_image"
require "dev/host_environment"
require "dev/host_rule"
require "dev/linux_data_root_provisioner"
require "fileutils"
require "pathname"
require "stringio"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::UpCommandTest < Minitest::Test
  include SorbetHelper

  def setup
    # The data root step is a host fact (Linux, default root); these tests
    # inject it where it is the subject and have none otherwise — on a
    # Linux CI runner the default would reach for sudo.
    Dev::LinuxDataRootProvisioner.stubs(:for_host).returns(nil)
  end

  test "traits: staleness-exempt (it IS the remediation) and stamps on success" do
    Given "the builtin"
    command = build_command

    Expect "the declarative traits"
    command.staleness_exempt? == true
    command.stamps? == true
    !command.hidden?
  end

  test "call ensures the dev cd shell hook and composes the dev deps install body" do
    Given "an up command with expectations on both collaborators"
    install_deps = install_deps_mock
    host_service = quiet_host_service
    host_service.expects(:install_rc_hook).once.returns(:already_present)
    command = Dev::Builtins::UpCommand.new(install_deps_command: install_deps, host_service: host_service)
    context = build_context

    When "running up"
    command.call(args: parsed_args(command, ["--pinned-taps"]), context: context)

    Then "the install body received the same args and context"
    1 * install_deps.call(args: parsed_args(command, ["--pinned-taps"]), context: context)
  end

  test "call converges the host tooling and links shipped skills as its host half" do
    Given "an up command whose host service expects the converge and the skill links"
    host_service = quiet_host_service
    host_service.expects(:converge_tooling).once
    host_service.expects(:sync_skills).with(project_root: nil).once
    install_deps = install_deps_mock
    install_deps.stubs(:call)
    command = Dev::Builtins::UpCommand.new(install_deps_command: install_deps, host_service: host_service)

    When "running up"
    command.call(args: no_args, context: build_context)

    Then "the expectations on the host service hold"
    true
  end

  test "call makes the Linux data root exist as part of the host half, before the install" do
    Given "a host whose data root step applies"
    install_deps = install_deps_mock
    provisioner = typed_mock(Dev::LinuxDataRootProvisioner)
    order = []
    provisioner.expects(:provision!).once.with { order.push(:root).any? }
    install_deps.expects(:call).once.with { |**| order.push(:install).any? }
    command = Dev::Builtins::UpCommand.new(
      install_deps_command: install_deps, host_service: quiet_host_service, data_root_provisioner: provisioner,
    )

    When
    command.call(args: no_args, context: build_context)

    Then "the root exists before anything installs into it"
    order == [:root, :install]
  end

  test "a projectless up still makes the data root: it is the machine's, not the project's" do
    Given
    host_service = typed_mock(Dev::HostService)
    host_service.stubs(:converge_tooling)
    host_service.stubs(:install_rc_hook)
    host_service.stubs(:sync_skills)
    host_service.stubs(:sync_learnings)
    provisioner = typed_mock(Dev::LinuxDataRootProvisioner)
    provisioner.expects(:provision!).once
    command = Dev::Builtins::UpCommand.new(
      install_deps_command: install_deps_mock, host_service: host_service, data_root_provisioner: provisioner,
    )

    When
    capture_stdout { command.call(args: no_args, context: Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui))) }

    Then
    true
  end

  test "call without a project converges the host half, syncs org learnings, and skips provisioning" do
    Given "a projectless context and a host service expecting only host work"
    host_service = typed_mock(Dev::HostService)
    host_service.expects(:converge_tooling).once
    host_service.expects(:install_rc_hook).once.returns(:added)
    host_service.expects(:sync_skills).with(project_root: nil).once
    host_service.expects(:sync_learnings).with(project_root: nil).once
    install_deps = install_deps_mock
    command = Dev::Builtins::UpCommand.new(install_deps_command: install_deps, host_service: host_service)
    context = Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui))

    When "running up outside any project"
    stdout = capture_stdout { command.call(args: no_args, context: context) }

    Then "deps install and credentials never run, and the bootstrap message points at projects"
    0 * install_deps.call(args: anything, context: anything)
    0 * Dev::Credentials.resolve_build_args(anything)
    stdout.include?("dev: host layer converged.")
    stdout.include?("no dev.yml here — run dev up inside a project to provision it too")
  end

  test "call resolves docker build arg credentials before anything else" do
    Given "a context whose build container declares build_args"
    command = build_command
    context = build_context(build_container: container_config(build_args: { "WWISE_EMAIL" => "wwise/email" }))

    When "running up"
    command.call(args: no_args, context: context)

    Then "build args are resolved (prompting and storing on first run)"
    1 * Dev::Credentials.resolve_build_args({ "WWISE_EMAIL" => "wwise/email" })
  end

  test "call skips credential provisioning without a build container" do
    Given "a context without a build container"
    command = build_command
    context = build_context

    When "running up"
    command.call(args: no_args, context: context)

    Then "credentials are never resolved"
    0 * Dev::Credentials.resolve_build_args(anything)
  end

  test "call skips credential provisioning when the container declares no build_args" do
    Given "a context whose build container has no build_args"
    command = build_command
    context = build_context(build_container: container_config(build_args: {}))

    When "running up"
    command.call(args: no_args, context: context)

    Then "credentials are never resolved"
    0 * Dev::Credentials.resolve_build_args(anything)
  end

  test "call brings the service dependencies up, in order, after the deps install they may depend on — through the port, not the CLI" do
    Given "two service dependencies; deps install and both bring-ups observed in order"
    order = sequence("deps, then services in order")
    install_deps = install_deps_mock
    install_deps.expects(:call).once.in_sequence(order)
    context = build_context(build_container: container_config(build_args: {}))
    first = typed_mock(Dev::Builtins::ContainerUpCommand)
    second = typed_mock(Dev::Builtins::ContainerUpCommand)
    first.expects(:up).with(project: context.project).once.in_sequence(order)
    second.expects(:up).with(project: context.project).once.in_sequence(order)
    first.expects(:call).never
    command = Dev::Builtins::UpCommand.new(
      install_deps_command: install_deps, host_service: quiet_host_service, service_dependencies: [first, second],
    )

    When "running up"
    command.call(args: no_args, context: context)

    Then "asserted on the mocks: the services are ready before the first command that needs them"
    true
  end

  test "inside the container, call is the deps install alone: no host converge, credentials or service bring-up" do
    Given "an inside up command whose host service and service dependency must stay untouched"
    host_service = typed_mock(Dev::HostService)
    install_deps = install_deps_mock
    service = typed_mock(Dev::Builtins::ContainerUpCommand)
    context = build_context(build_container: container_config(build_args: { "TOKEN" => "wwise/token" }))
    command = Dev::Builtins::UpCommand.new(
      install_deps_command: install_deps, host_service: host_service,
      service_dependencies: [service], inside_container: true,
    )

    When "running up inside"
    command.call(args: parsed_args(command, ["--group", "app"]), context: context)

    Then "only the install body ran, with the user's args"
    1 * install_deps.call(args: parsed_args(command, ["--group", "app"]), context: context)
    0 * host_service.converge_tooling
    0 * host_service.install_rc_hook
    0 * host_service.sync_skills
    0 * Dev::Credentials.resolve_build_args(anything)
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
    install_deps.expects(:call).never
    command = inside_up_command(install_deps, root)
    error = assert_raises(Dev::HostRule::ContainerDriftError) { command.call(args: no_args, context: inside_context(root)) }

    Expect
    error.message.include?("this container is snappy-linux@#{older.short_digest}")
    error.message.include?("re-create it from the host: `dev container reset && dev up`")

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "inside the container without a project, call explains there is nothing to provision" do
    Given "an inside up command and a projectless context"
    host_service = typed_mock(Dev::HostService)
    install_deps = install_deps_mock
    command = Dev::Builtins::UpCommand.new(
      install_deps_command: install_deps, host_service: host_service, inside_container: true,
    )
    context = Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui))

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
    seen = {}
    install_deps = install_deps_mock
    install_deps.expects(:call).with { |args:, context:|
      seen[:install_args] = args
      seen[:install_root] = ENV.fetch("DEV_DATA_ROOT")
      context.project
    }.once
    service = typed_mock(Dev::Builtins::ContainerUpCommand)
    service.expects(:cold_up).with { |project:|
      seen[:cold_root] = ENV.fetch("DEV_DATA_ROOT")
      project
    }.once
    service.expects(:up).never
    host_service = typed_mock(Dev::HostService)
    context = build_context(build_container: container_config(build_args: { "TOKEN" => "wwise/token" }))
    Dev::Credentials.stubs(:resolve_build_args).returns({ "TOKEN" => "x" })
    command = Dev::Builtins::UpCommand.new(
      install_deps_command: install_deps, host_service: host_service, service_dependencies: [service],
    )

    When "running dev up --no-cache --group app"
    command.call(args: parsed_args(command, ["--no-cache", "--group", "app"]), context: context)

    Then "both halves ran under one throwaway sibling of the warm root, which is gone and restored afterwards"
    seen[:install_args] == parsed_args(command, ["--no-cache", "--group", "app"])
    seen[:install_root].start_with?("#{warm}-cold-")
    seen[:cold_root] == seen[:install_root]
    !File.exist?(seen[:cold_root])
    ENV.fetch("DEV_DATA_ROOT") == warm
    1 * Dev::Credentials.resolve_build_args({ "TOKEN" => "wwise/token" })
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
    command = Dev::Builtins::UpCommand.new(install_deps_command: install_deps, host_service: host_service)
    context = Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui))

    When "running dev up --no-cache"
    stdout = capture_stdout { command.call(args: parsed_args(command, ["--no-cache"]), context: context) }

    Then "nothing ran and the message says why"
    0 * install_deps.call(args: anything, context: anything)
    0 * host_service.converge_tooling
    stdout.include?("dev up --no-cache needs a project")
  end

  test "inside the container, --no-cache is a host-side topology: it is reported and the plain install runs" do
    Given "an inside up command"
    install_deps = install_deps_mock
    command = Dev::Builtins::UpCommand.new(
      install_deps_command: install_deps, host_service: typed_mock(Dev::HostService), inside_container: true,
    )
    context = build_context

    When "running dev up --no-cache inside"
    stdout = capture_stdout { command.call(args: parsed_args(command, ["--no-cache"]), context: context) }

    Then "the install ran with the same args (the flag is not one it reads) and the output explains"
    1 * install_deps.call(args: parsed_args(command, ["--no-cache"]), context: context)
    stdout.include?("--no-cache runs from the host")
  end

  test "call with no service dependencies is the deps install alone" do
    Given "a plain project"
    install_deps = install_deps_mock
    install_deps.expects(:call).once
    command = Dev::Builtins::UpCommand.new(
      install_deps_command: install_deps, host_service: quiet_host_service, service_dependencies: [],
    )

    When "running up"
    command.call(args: no_args, context: build_context)

    Then
    true
  end

  private

  def build_command
    install_deps = install_deps_mock
    install_deps.stubs(:call)
    Dev::Builtins::UpCommand.new(
      install_deps_command: install_deps, host_service: quiet_host_service, service_dependencies: [],
    )
  end

  # The install body as a strict mock that still exposes its vocabulary:
  # `up` composes its own flags from it, so parsing `up`'s args needs it.
  def install_deps_mock
    install_deps = typed_mock(Dev::Builtins::InstallDepsCommand)
    install_deps.stubs(:flags).returns([
      Dev::Cli::Flag.new(Dev::Builtins::InstallDepsCommand::GROUP_FLAG, takes_value: true),
      Dev::Cli::Flag.new(Dev::Builtins::InstallDepsCommand::PINNED_TAPS_FLAG),
    ])
    install_deps
  end

  def quiet_host_service
    host_service = typed_mock(Dev::HostService)
    host_service.stubs(:converge_tooling)
    host_service.stubs(:install_rc_hook).returns(:already_present)
    host_service.stubs(:sync_skills)
    host_service
  end

  def container_config(build_args:)
    Dev::BuildContainerConfig.new(image: "myapp-linux", registry: "myregistry", build_args: build_args)
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
    host_rule = Dev::HostRule.new(
      host_environment: Dev::HostEnvironment.new(path: (root / "marker").to_s), host_platform: "linux-x86_64",
    )
    Dev::Builtins::UpCommand.new(
      install_deps_command: install_deps, host_service: typed_mock(Dev::HostService), inside_container: true, host_rule: host_rule,
    )
  end

  def inside_context(root)
    Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui), project: Dev::ProjectContext.new(name: "snappy", root: root))
  end

  def build_context(build_container: nil)
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui),
      project: Dev::ProjectContext.new(
        name: "TestProject",
        root: Pathname.new("/tmp/up-test"),
        build_container: build_container,
      ),
    )
  end
end

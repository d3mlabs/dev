# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/container_up_command"
require "dev/builtins/container_down_command"
require "dev/builtins/container_reset_command"
require "dev/builtins/container_tag_command"
require "dev/builtins/container_status_command"
require "dev/build_container_config"
require "dev/container_dev_provisioner"
require "dev/engine_provisioner"
require "support/fake_container_engine"
require "pathname"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::ContainerCommandsTest < Minitest::Test
  include SorbetHelper

  ROOT = Pathname.new("/tmp/container-commands-test")
  TAG = "myregistry/myapp-linux:content-abc123"
  CURRENT = "dev-myapp-linux-abc-content-abc123"

  # --- traits -----------------------------------------------------------------

  test "#{klass} is a visible Lifecycle verb; #{klass} is staleness-exempt: #{exempt}" do
    Given "the builtin over a stand-in client"
    command = klass.new(container_client: client, out: StringIO.new)

    Expect "the declarative traits"
    command.category == Dev::Command::Category::Lifecycle
    command.hidden? == false
    command.staleness_exempt? == exempt
    command.stamps? == false

    Where
    klass                                   | exempt
    Dev::Builtins::ContainerUpCommand       | true
    Dev::Builtins::ContainerDownCommand     | true
    Dev::Builtins::ContainerResetCommand    | true
    Dev::Builtins::ContainerTagCommand      | true
    Dev::Builtins::ContainerStatusCommand   | true
  end

  test "#{klass} is the #{port} port dev up / dev down compose; its CLI verb is the adapter over it" do
    Given "the builtin"
    command = klass.new(container_client: client, out: StringIO.new)
    context = project(config(persist: true))
    command.expects(verb).with(project: context.project).once

    When "invoked as a CLI verb"
    command.call(args: [], context: context)

    Then "it is the port, and the verb delegated to it with the project alone"
    command.is_a?(port)

    Where
    klass                                 | port                       | verb
    Dev::Builtins::ContainerUpCommand     | Dev::Builtins::ServiceUp   | :up
    Dev::Builtins::ContainerDownCommand   | Dev::Builtins::ServiceDown | :down
  end

  # --- up ---------------------------------------------------------------------

  test "container up brings the engine up from the hint, resolves the image, and starts the service when persisted" do
    Given "a persisted config, with every boundary stubbed"
    config = config(persist: true, volumes: ["~/.dev/engines/ue:/ue"])
    order = sequence("engine, image, service")
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.expects(:provision!).with(resources: config.resources).once.in_sequence(order)
    client = client()
    client.expects(:ensure_image!).with do |cfg, **kwargs|
      cfg == config && kwargs[:project_root] == ROOT && kwargs[:push] == false && kwargs[:publish] == false
    end.once.in_sequence(order).returns(TAG)
    Dev::BuildContainer.stubs(:resolve_versioned_volumes).with(["~/.dev/engines/ue:/ue"], project_root: ROOT)
      .returns(["~/.dev/engines/ue/5.4:/ue"])
    client.expects(:ensure_service!).with(TAG, project_root: ROOT, volumes: ["~/.dev/engines/ue/5.4:/ue"])
      .once.in_sequence(order).returns("dev-myapp-linux-abc-content-abc123")
    dev_provisioner = typed_mock(Dev::ContainerDevProvisioner)
    dev_provisioner.stubs(:host_version).returns("0.2.98")
    dev_provisioner.expects(:provision!).with("dev-myapp-linux-abc-content-abc123").once.in_sequence(order)
      .returns(:installed)
    deps_installer = typed_mock(Dev::ContainerDepsInstaller)
    deps_installer.expects(:install!).with("dev-myapp-linux-abc-content-abc123", env: {}).once.in_sequence(order)
    out = StringIO.new

    When "bringing the container up"
    Dev::Builtins::ContainerUpCommand.new(
      container_client: client, engine_provisioner: provisioner, dev_provisioner: dev_provisioner,
      deps_installer: deps_installer, out: out,
    ).call(args: [], context: project(config))

    Then "every step is reported: the container's dev, then the deps it installs"
    out.string == "dev: image ready: #{TAG}\n" \
      "dev: build container up: dev-myapp-linux-abc-content-abc123\n" \
      "dev: container dev installed at 0.2.98\n" \
      "dev: container deps installed\n"
  end

  test "container up injects the resolvable run_env into the in-container install" do
    Given "a persisted config declaring run_env, one entry resolvable"
    config = Dev::BuildContainerConfig.new(
      image: "myapp-linux", registry: "myregistry", persist: true,
      run_env: { "WWISE_TOKEN" => "wwise/token", "MISSING" => "x/y" },
    )
    Dev::Credentials.stubs(:load).returns(nil)
    Dev::Credentials.stubs(:load).with("wwise", "token").returns("t0k")
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.stubs(:provision!)
    client = client()
    client.stubs(:ensure_image!).returns(TAG)
    client.stubs(:ensure_service!).returns(CURRENT)
    dev_provisioner = typed_mock(Dev::ContainerDevProvisioner)
    dev_provisioner.stubs(:host_version).returns("0.2.98")
    dev_provisioner.stubs(:provision!).returns(:current)
    deps_installer = typed_mock(Dev::ContainerDepsInstaller)

    When "bringing the container up"
    Dev::Builtins::ContainerUpCommand.new(
      container_client: client, engine_provisioner: provisioner, dev_provisioner: dev_provisioner,
      deps_installer: deps_installer, out: StringIO.new,
    ).call(args: [], context: project(config))

    Then "the install sees the resolved entry only"
    1 * deps_installer.install!(CURRENT, env: { "WWISE_TOKEN" => "t0k" })
  end

  test "container up reports the container's dev as current when the provisioner found nothing to do" do
    Given "a persisted config whose container already carries the host's dev"
    config = config(persist: true)
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.stubs(:provision!)
    client = client()
    client.stubs(:ensure_image!).returns(TAG)
    client.stubs(:ensure_service!).returns(CURRENT)
    dev_provisioner = typed_mock(Dev::ContainerDevProvisioner)
    dev_provisioner.stubs(:host_version).returns("0.2.98")
    dev_provisioner.stubs(:provision!).returns(:current)
    out = StringIO.new

    When "bringing the container up"
    Dev::Builtins::ContainerUpCommand.new(
      container_client: client, engine_provisioner: provisioner, dev_provisioner: dev_provisioner, out: out,
    ).call(args: [], context: project(config))

    Then
    out.string.include?("dev: container dev current at 0.2.98\n")
  end

  test "container up on a non-persisted project stops at the image" do
    Given "a config without persist"
    config = config(persist: false)
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.stubs(:provision!)
    client = client()
    client.stubs(:ensure_image!).returns(TAG)
    client.expects(:ensure_service!).never
    out = StringIO.new

    When "bringing the container up"
    Dev::Builtins::ContainerUpCommand.new(container_client: client, engine_provisioner: provisioner, out: out)
      .call(args: [], context: project(config))

    Then
    out.string == "dev: image ready: #{TAG}\n"
  end

  test "container up publishes to the registry only when DEV_PUBLISH_IMAGE=1" do
    Given "the env flag #{flag.inspect}"
    config = config(persist: false)
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.stubs(:provision!)
    client = client()
    captured = {}
    client.stubs(:ensure_image!).with do |_cfg, **kwargs|
      captured = kwargs
      true
    end.returns(TAG)
    old = ENV.fetch("DEV_PUBLISH_IMAGE", nil)
    flag.nil? ? ENV.delete("DEV_PUBLISH_IMAGE") : ENV["DEV_PUBLISH_IMAGE"] = flag

    When "bringing the container up"
    Dev::Builtins::ContainerUpCommand.new(container_client: client, engine_provisioner: provisioner, out: StringIO.new)
      .call(args: [], context: project(config))

    Then
    captured.fetch(:publish) == publish

    Cleanup
    old.nil? ? ENV.delete("DEV_PUBLISH_IMAGE") : ENV["DEV_PUBLISH_IMAGE"] = old

    Where
    flag  | publish
    nil   | false
    "0"   | false
    "1"   | true
  end

  test "container up's providers resolve the declared build args and secrets through the credentials store, lazily" do
    Given "a config declaring build args and secrets, with both boundaries stubbed"
    config = config(persist: false, build_args: { "GH_USER" => "github/user" },
      build_secrets: { "GH_TOKEN" => "github/token" })
    Dev::Credentials.stubs(:resolve_build_args).with({ "GH_USER" => "github/user" }).returns({ "GH_USER" => "jp" })
    Dev::Credentials.stubs(:resolve_build_args).with({ "GH_TOKEN" => "github/token" }).returns({ "GH_TOKEN" => "s3" })
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.stubs(:provision!)
    client = client()
    captured = {}
    client.stubs(:ensure_image!).with do |_cfg, **kwargs|
      captured = kwargs
      true
    end.returns(TAG)

    When "bringing the container up, then invoking the providers ensure_image! received"
    Dev::Builtins::ContainerUpCommand.new(container_client: client, engine_provisioner: provisioner, out: StringIO.new)
      .call(args: [], context: project(config))

    Then "each provider resolves its declared credentials"
    captured.fetch(:build_args_provider).call == { "GH_USER" => "jp" }
    captured.fetch(:secrets_provider).call == { "GH_TOKEN" => "s3" }
  end

  # --- down / reset -----------------------------------------------------------

  test "container down stops this checkout's running containers and names them: #{description}" do
    Given "a client whose stop_service! reports #{stopped.inspect}"
    client = client()
    client.expects(:stop_service!).with(ROOT).once.returns(stopped)
    out = StringIO.new

    When "bringing the container down"
    Dev::Builtins::ContainerDownCommand.new(container_client: client, out: out)
      .call(args: [], context: project(config(persist: true)))

    Then
    out.string == expected

    Where
    description       | stopped                   | expected
    "nothing running" | []                        | "dev: no build container running.\n"
    "one stopped"     | ["dev-myapp-abc-content"] | "dev: stopped dev-myapp-abc-content — incremental state kept, dev container up restarts it warm.\n"
    "two stopped"     | ["dev-a", "dev-b"]        | "dev: stopped dev-a, dev-b — incremental state kept, dev container up restarts it warm.\n"
  end

  test "container reset removes this checkout's containers and names them: #{description}" do
    Given "a client whose reset_service! reports #{removed.inspect}"
    client = client()
    client.expects(:reset_service!).with(ROOT).once.returns(removed)
    out = StringIO.new

    When "resetting"
    Dev::Builtins::ContainerResetCommand.new(container_client: client, out: out)
      .call(args: [], context: project(config(persist: true)))

    Then
    out.string == expected

    Where
    description | removed                   | expected
    "none"      | []                        | "dev: no build container to remove.\n"
    "one"       | ["dev-myapp-abc-content"] | "dev: removed dev-myapp-abc-content.\n"
    "two"       | ["dev-a", "dev-b"]        | "dev: removed dev-a, dev-b.\n"
  end

  # --- tag --------------------------------------------------------------------

  test "container tag prints the content-addressed tag and nothing else, touching no engine" do
    Given "a config and a client that must not be used"
    config = config(persist: false)
    client = client()
    client.expects(:ensure_image!).never
    Dev::BuildContainer.stubs(:image_with_tag).with(config, project_root: ROOT).returns(TAG)
    out = StringIO.new

    When "printing the tag"
    Dev::Builtins::ContainerTagCommand.new(container_client: client, out: out).call(args: [], context: project(config))

    Then "a workflow can capture it"
    out.string == "#{TAG}\n"
  end

  # --- status -----------------------------------------------------------------

  test "container status renders the image line: #{description}" do
    Given "an image #{description}"
    status = status(local: local, registry: registry, containers: [])

    Expect
    status_output(status, persist: true).lines.first == "image: #{TAG} — #{rendered}\n"

    Where
    description                      | local | registry | rendered
    "local and published"            | true  | true     | "local, in registry"
    "local only"                     | true  | false    | "local, not in registry"
    "published, not pulled"          | false | true     | "in registry, not local (dev container up pulls it)"
    "nowhere"                        | false | false    | "not built (dev container up builds it)"
  end

  test "container status renders the persisted container: #{description}" do
    Given "a persisted project whose containers are #{description}"
    status = status(local: true, registry: true, containers: containers)

    Expect
    status_output(status, persist: true).lines.drop(1) == expected

    Where
    description             | containers                                                   | expected
    "absent"                | []                                                           | ["container: none (dev container up creates it)\n"]
    "running"               | [[CURRENT, true]]                                            | ["container: #{CURRENT} — running\n"]
    "stopped"               | [[CURRENT, false]]                                           | ["container: #{CURRENT} — stopped (dev container up restarts it warm)\n"]
    "current plus a stale"  | [["dev-myapp-linux-abc-content-old", false], [CURRENT, true]] | ["container: #{CURRENT} — running\n", "stale: dev-myapp-linux-abc-content-old — stopped (dev container up removes it)\n"]
    "only a stale one"      | [["dev-myapp-linux-abc-content-old", true]] | ["container: none (dev container up creates it)\n", "stale: dev-myapp-linux-abc-content-old — running (dev container up removes it)\n"]
  end

  test "container status on a non-persisted project reports the --rm runs in flight: #{description}" do
    Given "a non-persisted project with #{description}"
    status = status(local: true, registry: true, containers: containers)

    Expect
    status_output(status, persist: false).lines.drop(1) == expected

    Where
    description      | containers                | expected
    "nothing"        | []                        | ["container: not persisted (build.container.persist is off); none in flight\n"]
    "a run going"    | [["dev-myapp-x", true]]   | ["container: not persisted (build.container.persist is off); in flight: dev-myapp-x\n"]
  end

  private

  def client
    Dev::BuildContainer.new(engine: FakeContainerEngine.new)
  end

  def config(persist:, volumes: [], build_args: {}, build_secrets: {})
    Dev::BuildContainerConfig.new(
      image: "myapp-linux", registry: "myregistry", persist: persist, volumes: volumes,
      build_args: build_args, build_secrets: build_secrets,
    )
  end

  def project(build_container)
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui),
      project: Dev::ProjectContext.new(
        name: "TestProject", root: ROOT, ruby_version: "4.0.1", build_container: build_container,
      ),
    )
  end

  def status(local:, registry:, containers:)
    Dev::BuildContainer::ServiceStatus.new(
      image_tag: TAG, local_image: local, in_registry: registry, current_container_name: CURRENT,
      containers: containers.map { |name, running| Dev::BuildContainer::ServiceContainer.new(name:, running:) },
    )
  end

  def status_output(status, persist:)
    config = config(persist: persist)
    client = client()
    Dev::BuildContainer.stubs(:image_with_tag).with(config, project_root: ROOT).returns(TAG)
    client.stubs(:service_status).with(TAG, ROOT).returns(status)
    out = StringIO.new
    Dev::Builtins::ContainerStatusCommand.new(container_client: client, out: out).call(args: [], context: project(config))
    out.string
  end
end

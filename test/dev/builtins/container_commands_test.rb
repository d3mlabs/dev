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
require "dev/deps/dependency"
require "dev/deps/lockfile"
require "dev/environment_image"
require "dev/host_environment"
require "dev/host_rule"
require "dev/container_user_aligner"
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
    command.call(args: no_args, context: context)

    Then "it is the port, and the verb delegated to it with the project alone"
    command.is_a?(port)

    Where
    klass                                 | port                       | verb
    Dev::Builtins::ContainerUpCommand     | Dev::Builtins::ServiceUp   | :up
    Dev::Builtins::ContainerDownCommand   | Dev::Builtins::ServiceDown | :down
  end

  # --- up ---------------------------------------------------------------------

  test "container up brings the engine up from the hint, resolves the image, and starts the service when persisted" do
    Given "a persisted config and an engine hint, with every boundary stubbed"
    config = config(persist: true, volumes: ["~/.dev/engines/ue:/ue"])
    engine = Dev::EngineResources::Hint.new(cpus: 8, memory_gib: 24)
    order = sequence("engine, image, service")
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.expects(:provision!).with(resources: engine).once.in_sequence(order)
    client = client()
    client.expects(:ensure_image!).with do |cfg, **kwargs|
      cfg == config && kwargs[:project_root] == ROOT && kwargs[:push] == false && kwargs[:publish] == false
    end.once.in_sequence(order).returns(TAG)
    client.expects(:ensure_service!).with(TAG, project_root: ROOT, volumes: ["~/.dev/engines/ue:/ue"])
      .once.in_sequence(order).returns("dev-myapp-linux-abc-content-abc123")
    user_aligner = typed_mock(Dev::ContainerUserAligner)
    user_aligner.expects(:align!).with("dev-myapp-linux-abc-content-abc123").once.in_sequence(order).returns(:aligned)
    dev_provisioner = typed_mock(Dev::ContainerDevProvisioner)
    dev_provisioner.stubs(:host_version).returns("0.2.98")
    dev_provisioner.expects(:provision!).with("dev-myapp-linux-abc-content-abc123").once.in_sequence(order)
      .returns(:installed)
    deps_installer = typed_mock(Dev::ContainerDepsInstaller)
    deps_installer.expects(:install!).with("dev-myapp-linux-abc-content-abc123", env: {}).once.in_sequence(order)
    out = StringIO.new

    When "bringing the container up"
    Dev::Builtins::ContainerUpCommand.new(
      container_client: client, engine_provisioner: provisioner, user_aligner: user_aligner,
      dev_provisioner: dev_provisioner, deps_installer: deps_installer, out: out,
    ).call(args: no_args, context: project(config, engine: engine))

    Then "every step is reported: the container's dev, then the deps it installs — an already-aligned user says nothing"
    out.string == "dev: image ready: #{TAG}\n" \
      "dev: build container up: dev-myapp-linux-abc-content-abc123\n" \
      "dev: container dev installed at 0.2.98\n" \
      "dev: container deps installed\n"
  end

  test "container up with an image pin resolves through ensure_environment_image!, the engine hint along" do
    Given "a checkout whose lock pins its image and whose dev.yml has no container block"
    root = project_root_pinning("linux/amd64")
    engine = Dev::EngineResources::Hint.new(cpus: 8)
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.expects(:provision!).with(resources: engine).once
    client = client()
    client.expects(:ensure_image!).never
    client.expects(:ensure_environment_image!).once
      .with { |image, publish:, resources:| image.name == "myapp-linux" && !publish && resources.cpus == 8 }
      .returns("ghcr.io/d3mlabs/myapp-linux:deadbeef")
    out = StringIO.new

    When "bringing the container up on a host that is not the environment"
    Dev::Builtins::ContainerUpCommand.new(
      container_client: client, engine_provisioner: provisioner, out: out, host_rule: rule("darwin-arm64"),
    ).call(args: no_args, context: project(nil, root: root, engine: engine))

    Then
    out.string == "dev: image ready: ghcr.io/d3mlabs/myapp-linux:deadbeef\n"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "container up over two images: the engine sized once, each image resolved, a service only for the persisted one, in its shape" do
    Given "a lock pinning a persisted image with volumes and run_env, and a plain one"
    root = project_root_pinning("linux/amd64", images: {
      "snappy-linux" => { "persist" => true, "volumes" => ["/e:/ue"], "run_env" => { "WWISE_TOKEN" => "wwise/token" } },
      "snappy-server" => {},
    })
    Dev::Credentials.stubs(:load).returns(nil)
    Dev::Credentials.stubs(:load).with("wwise", "token").returns("t0k")
    engine = Dev::EngineResources::Hint.new(cpus: 8)
    order = sequence("engine once, then image by image")
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.expects(:provision!).with(resources: engine).once.in_sequence(order)
    client = client()
    client.expects(:ensure_environment_image!).with { |image, **| image.name == "snappy-linux" }
      .once.in_sequence(order).returns("ghcr.io/d3mlabs/snappy-linux:aaaa")
    client.expects(:ensure_service!).with("ghcr.io/d3mlabs/snappy-linux:aaaa", project_root: root, volumes: ["/e:/ue"])
      .once.in_sequence(order).returns("dev-snappy-linux-ws-aaaa")
    deps_installer = typed_mock(Dev::ContainerDepsInstaller)
    deps_installer.expects(:install!).with("dev-snappy-linux-ws-aaaa", env: { "WWISE_TOKEN" => "t0k" }).once.in_sequence(order)
    client.expects(:ensure_environment_image!).with { |image, **| image.name == "snappy-server" }
      .once.in_sequence(order).returns("ghcr.io/d3mlabs/snappy-server:bbbb")
    dev_provisioner = typed_mock(Dev::ContainerDevProvisioner)
    dev_provisioner.stubs(:host_version).returns("0.5.0")
    dev_provisioner.stubs(:provision!).returns(:current)
    out = StringIO.new

    When
    Dev::Builtins::ContainerUpCommand.new(
      container_client: client, engine_provisioner: provisioner, user_aligner: aligned_user,
      dev_provisioner: dev_provisioner, deps_installer: deps_installer, out: out, host_rule: rule("darwin-arm64"),
    ).call(args: no_args, context: project(nil, root: root, engine: engine))

    Then "one service — the persisted image's; the plain one stops at its image"
    out.string == "dev: image ready: ghcr.io/d3mlabs/snappy-linux:aaaa\n" \
      "dev: build container up: dev-snappy-linux-ws-aaaa\n" \
      "dev: container dev current at 0.5.0\n" \
      "dev: container deps installed\n" \
      "dev: image ready: ghcr.io/d3mlabs/snappy-server:bbbb\n"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "the host rule is asked per image: a host provisioned from one image skips that one and brings the other up" do
    Given "two linux/amd64 images, on a linux-x86_64 host whose marker is one of them"
    root = project_root_pinning("linux/amd64", images: { "snappy-linux" => {}, "snappy-server" => {} })
    server = pinned(root).find { |image| image.name == "snappy-server" }
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.expects(:provision!).once
    client = client()
    client.expects(:ensure_environment_image!).once.with { |image, **| image.name == "snappy-linux" }.returns("ref-linux")
    out = StringIO.new

    When
    Dev::Builtins::ContainerUpCommand.new(
      container_client: client, engine_provisioner: provisioner, out: out,
      host_rule: rule("linux-x86_64", marker: marker_for(root, server)),
    ).call(args: no_args, context: project(nil, root: root))

    Then "the linux image is brought up though the host is its platform too; the server image is the host's own"
    out.string == "dev: image ready: ref-linux\n" \
      "dev: this host was provisioned from snappy-server@#{server.short_digest} — snappy-server's commands run here, no container\n"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a host provisioned from an older recipe of the image has drifted: brought up like any other host, and told both digests" do
    Given "the marker names the image under another digest"
    root = project_root_pinning("linux/amd64", images: { "snappy-linux" => {} })
    current = pinned(root).first
    older = Dev::EnvironmentImage.new(
      name: current.name, from: current.from, from_digest: current.from_digest, platform: current.platform,
      apt: ["libnss3"], registry: current.registry,
    )
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.expects(:provision!).once
    client = client()
    client.expects(:ensure_environment_image!).once.returns("ref-linux")
    out = StringIO.new

    When
    Dev::Builtins::ContainerUpCommand.new(
      container_client: client, engine_provisioner: provisioner, out: out,
      host_rule: rule("linux-x86_64", marker: marker_for(root, older)),
    ).call(args: no_args, context: project(nil, root: root))

    Then
    out.string == "dev: this host was provisioned from snappy-linux@#{older.short_digest} but the lock's snappy-linux is " \
      "snappy-linux@#{current.short_digest} — its commands run inside until this host is re-imaged\n" \
      "dev: image ready: ref-linux\n"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "container up reports a user alignment that did something: #{result}" do
    Given "a persisted config whose container's user could not write the data root"
    config = config(persist: true)
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.stubs(:provision!)
    client = client()
    client.stubs(:ensure_image!).returns(TAG)
    client.stubs(:ensure_service!).returns(CURRENT)
    user_aligner = typed_mock(Dev::ContainerUserAligner)
    user_aligner.stubs(:align!).returns(result)
    dev_provisioner = typed_mock(Dev::ContainerDevProvisioner)
    dev_provisioner.stubs(:host_version).returns("0.2.98")
    dev_provisioner.stubs(:provision!).returns(:current)
    deps_installer = typed_mock(Dev::ContainerDepsInstaller)
    deps_installer.stubs(:install!)
    out = StringIO.new

    When "bringing the container up"
    Dev::Builtins::ContainerUpCommand.new(
      container_client: client, engine_provisioner: provisioner, user_aligner: user_aligner,
      dev_provisioner: dev_provisioner, deps_installer: deps_installer, out: out,
    ).call(args: no_args, context: project(config))

    Then "the alignment is reported before the container's dev"
    out.string.include?("dev: build container up: #{CURRENT}\n#{line}\ndev: container dev current at 0.2.98\n")

    Where
    result          | line
    :realigned      | "dev: container user took the ids its data root calls for"
    :adopted        | "dev: container user took over the root-owned data root"
    :prefix_adopted | "dev: container user took over its Linuxbrew prefix volume"
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
      container_client: client, engine_provisioner: provisioner, user_aligner: aligned_user,
      dev_provisioner: dev_provisioner, deps_installer: deps_installer, out: StringIO.new,
    ).call(args: no_args, context: project(config))

    Then "the install sees the resolved entry only"
    1 * deps_installer.install!(CURRENT, env: { "WWISE_TOKEN" => "t0k" })
  end

  # --- cold_up ----------------------------------------------------------------

  test "cold_up resolves the image, then provisions dev and installs deps in a one-shot container — never the persistent one" do
    Given "a persisted config whose boundaries record what they see"
    config = config(persist: true, volumes: ["~/.dev/engines/ue:/ue"])
    order = sequence("engine, image, one-shot: dev then deps")
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.expects(:provision!).with(resources: nil).once.in_sequence(order)
    client = client()
    client.expects(:ensure_image!).once.in_sequence(order).returns(TAG)
    client.expects(:ensure_service!).never
    client.expects(:with_one_shot_container).with(TAG, project_root: ROOT, volumes: ["~/.dev/engines/ue:/ue"])
      .once.in_sequence(order).yields("dev-myapp-cold-1234")
    user_aligner = typed_mock(Dev::ContainerUserAligner)
    user_aligner.expects(:align!).with("dev-myapp-cold-1234").once.in_sequence(order).returns(:aligned)
    dev_provisioner = typed_mock(Dev::ContainerDevProvisioner)
    dev_provisioner.stubs(:host_version).returns("0.2.98")
    dev_provisioner.expects(:provision!).with("dev-myapp-cold-1234").once.in_sequence(order).returns(:installed)
    deps_installer = typed_mock(Dev::ContainerDepsInstaller)
    deps_installer.expects(:install!).with("dev-myapp-cold-1234", env: {}).once.in_sequence(order)
    out = StringIO.new

    When "cold-upping"
    Dev::Builtins::ContainerUpCommand.new(
      container_client: client, engine_provisioner: provisioner, user_aligner: user_aligner,
      dev_provisioner: dev_provisioner, deps_installer: deps_installer, out: out,
    ).cold_up(project: project(config).project)

    Then "the steps are reported against the one-shot container"
    out.string == "dev: image ready: #{TAG}\n" \
      "dev: cold container up: dev-myapp-cold-1234\n" \
      "dev: container dev installed at 0.2.98\n" \
      "dev: container deps installed\n"
  end

  test "cold_up runs the one-shot install for a non-persisted project too: the topology is the same" do
    Given "a non-persisted config"
    config = config(persist: false)
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.stubs(:provision!)
    client = client()
    client.stubs(:ensure_image!).returns(TAG)
    client.expects(:with_one_shot_container).with(TAG, project_root: ROOT, volumes: []).once.yields("dev-myapp-cold-1")
    dev_provisioner = typed_mock(Dev::ContainerDevProvisioner)
    dev_provisioner.stubs(:host_version).returns("0.2.98")
    dev_provisioner.stubs(:provision!).returns(:installed)
    deps_installer = typed_mock(Dev::ContainerDepsInstaller)

    When "cold-upping"
    Dev::Builtins::ContainerUpCommand.new(
      container_client: client, engine_provisioner: provisioner, user_aligner: aligned_user,
      dev_provisioner: dev_provisioner, deps_installer: deps_installer, out: StringIO.new,
    ).cold_up(project: project(config).project)

    Then "the install ran inside the one-shot container"
    1 * deps_installer.install!("dev-myapp-cold-1", env: {})
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
      container_client: client, engine_provisioner: provisioner, user_aligner: aligned_user,
      dev_provisioner: dev_provisioner, out: out,
    ).call(args: no_args, context: project(config))

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
      .call(args: no_args, context: project(config))

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
      .call(args: no_args, context: project(config))

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

  test "on a host that is the environment, container up touches nothing: no engine, no image, no container" do
    Given "a persisted config in a project whose Dockerfile declares the host's own platform"
    config = config(persist: true)
    root = project_root_declaring("linux/amd64")
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.expects(:provision!).never
    client = client()
    client.expects(:ensure_image!).never
    client.expects(:ensure_service!).never
    out = StringIO.new

    When "bringing the container up on a linux-x86_64 host"
    Dev::Builtins::ContainerUpCommand.new(
      container_client: client, engine_provisioner: provisioner, out: out, host_rule: rule("linux-x86_64"),
    ).call(args: no_args, context: project(config, root: root))

    Then "it says why once and stops"
    out.string == "dev: this host is the build environment (linux-x86_64) — myapp-linux's commands run here, no container\n"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "on a host that is the environment, DEV_PUBLISH_IMAGE=1 still publishes the image — and still starts no container" do
    Given "the publisher designation, on a linux-x86_64 host of a linux/amd64 environment"
    config = config(persist: true)
    root = project_root_declaring("linux/amd64")
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.expects(:provision!).with(resources: nil).once
    client = client()
    client.expects(:ensure_image!).with do |cfg, **kwargs|
      cfg == config && kwargs[:project_root] == root && kwargs[:publish] == true
    end.once.returns(TAG)
    client.expects(:ensure_service!).never
    out = StringIO.new
    old = ENV.fetch("DEV_PUBLISH_IMAGE", nil)
    ENV["DEV_PUBLISH_IMAGE"] = "1"

    When "bringing the container up"
    Dev::Builtins::ContainerUpCommand.new(
      container_client: client, engine_provisioner: provisioner, out: out, host_rule: rule("linux-x86_64"),
    ).call(args: no_args, context: project(config, root: root))

    Then "the image is resolved for the registry's sake, then the rule applies"
    out.string == "dev: image ready: #{TAG}\n" \
      "dev: this host is the build environment (linux-x86_64) — myapp-linux's commands run here, no container\n"

    Cleanup
    old.nil? ? ENV.delete("DEV_PUBLISH_IMAGE") : ENV["DEV_PUBLISH_IMAGE"] = old
    FileUtils.rm_rf(root)
  end

  test "on a host of another platform, container up is unchanged by the declaration" do
    Given "a linux/amd64 environment on a darwin-arm64 host"
    config = config(persist: false)
    root = project_root_declaring("linux/amd64")
    provisioner = typed_mock(Dev::EngineProvisioner)
    provisioner.stubs(:provision!)
    client = client()
    client.expects(:ensure_image!).once.returns(TAG)
    out = StringIO.new

    When "bringing the container up"
    Dev::Builtins::ContainerUpCommand.new(
      container_client: client, engine_provisioner: provisioner, out: out, host_rule: rule("darwin-arm64"),
    ).call(args: no_args, context: project(config, root: root))

    Then
    out.string == "dev: image ready: #{TAG}\n"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "cold_up on a host that is the environment proves nothing a container could: it says so and stops" do
    Given "a linux/amd64 environment on a linux-x86_64 host"
    config = config(persist: true)
    root = project_root_declaring("linux/amd64")
    client = client()
    client.expects(:ensure_image!).never
    client.expects(:with_one_shot_container).never
    out = StringIO.new

    When "running the cold bring-up"
    Dev::Builtins::ContainerUpCommand.new(
      container_client: client, engine_provisioner: typed_mock(Dev::EngineProvisioner), out: out,
      host_rule: rule("linux-x86_64"),
    ).cold_up(project: project(config, root: root).project!)

    Then
    out.string == "dev: this host is the build environment (linux-x86_64) — myapp-linux's commands run here, no container\n"

    Cleanup
    FileUtils.rm_rf(root)
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
      .call(args: no_args, context: project(config))

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
      .call(args: no_args, context: project(config(persist: true)))

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
      .call(args: no_args, context: project(config(persist: true)))

    Then
    out.string == expected

    Where
    description | removed                   | expected
    "none"      | []                        | "dev: no build container to remove.\n"
    "one"       | ["dev-myapp-abc-content"] | "dev: removed dev-myapp-abc-content.\n"
    "two"       | ["dev-a", "dev-b"]        | "dev: removed dev-a, dev-b.\n"
  end

  # --- tag --------------------------------------------------------------------

  test "container tag prints the image's name and content-addressed tag, tab-separated, touching no engine" do
    Given "a config and a client that must not be used"
    config = config(persist: false)
    client = client()
    client.expects(:ensure_image!).never
    Dev::BuildContainer.stubs(:image_with_tag).with(config, project_root: ROOT).returns(TAG)
    out = StringIO.new

    When "printing the tag"
    Dev::Builtins::ContainerTagCommand.new(container_client: client, out: out).call(args: no_args, context: project(config))

    Then "a workflow can capture it"
    out.string == "myapp-linux\t#{TAG}\n"
  end

  test "container tag prints one line per pinned image: its name and the digest tag the lock and the registry share" do
    Given
    root = project_root_pinning("linux/amd64", images: { "snappy-linux" => {}, "snappy-server" => {} })
    images = Dev::Deps::Lockfile.new(dir: root).read.map { |pin| Dev::EnvironmentImage.from_pin(pin) }
    out = StringIO.new

    When
    Dev::Builtins::ContainerTagCommand.new(container_client: client, out: out)
      .call(args: no_args, context: project(nil, root: root))

    Then
    out.string == images.map { |image| "#{image.name}\t#{image.ref}\n" }.join
    images.all? { |image| image.ref.end_with?(":#{image.digest}") }

    Cleanup
    FileUtils.rm_rf(root)
  end

  # --- status -----------------------------------------------------------------

  test "container status on a pinned image probes the registry inside its login and says what the image is: floor by digest, platform" do
    Given
    root = project_root_pinning("linux/arm64")
    image = Dev::EnvironmentImage.from_pin(Dev::Deps::Lockfile.new(dir: root).read.first)
    client = client()
    client.expects(:service_status).with(image.ref, root, registry: "ghcr.io").once.returns(
      Dev::BuildContainer::ServiceStatus.new(
        image_tag: image.ref, local_image: true, in_registry: true, current_container_name: CURRENT, containers: [],
      ),
    )
    out = StringIO.new

    When
    Dev::Builtins::ContainerStatusCommand.new(container_client: client, out: out)
      .call(args: no_args, context: project(nil, root: root))

    Then
    out.string.lines == [
      "image: myapp-linux — #{image.ref} — local, in registry\n",
      "floor: ghcr.io/d3mlabs/unreal-engine-build-base@sha256:#{"a" * 64}\n",
      "platform: linux/arm64\n",
      "container: not persisted (persist is off); none in flight\n",
    ]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "container status prints one block per image, blank-line separated, each with its own containers" do
    Given "two pinned images, the persisted one with a running container"
    root = project_root_pinning("linux/amd64", images: { "snappy-linux" => { "persist" => true }, "snappy-server" => {} })
    linux, server = Dev::Deps::Lockfile.new(dir: root).read.map { |pin| Dev::EnvironmentImage.from_pin(pin) }
    client = client()
    client.stubs(:service_status).with(linux.ref, root, registry: "ghcr.io").returns(
      Dev::BuildContainer::ServiceStatus.new(
        image_tag: linux.ref, local_image: true, in_registry: true, current_container_name: "dev-linux-ws-aaaa",
        containers: [Dev::BuildContainer::ServiceContainer.new(name: "dev-linux-ws-aaaa", running: true)],
      ),
    )
    client.stubs(:service_status).with(server.ref, root, registry: "ghcr.io").returns(
      Dev::BuildContainer::ServiceStatus.new(
        image_tag: server.ref, local_image: false, in_registry: true, current_container_name: "dev-server-ws-bbbb", containers: [],
      ),
    )
    out = StringIO.new

    When
    Dev::Builtins::ContainerStatusCommand.new(container_client: client, out: out).call(args: no_args, context: project(nil, root: root))

    Then
    out.string == "image: snappy-linux — #{linux.ref} — local, in registry\n" \
      "floor: #{linux.floor_ref}\n" \
      "platform: linux/amd64\n" \
      "container: dev-linux-ws-aaaa — running\n" \
      "\n" \
      "image: snappy-server — #{server.ref} — in registry, not local (dev container up pulls it)\n" \
      "floor: #{server.floor_ref}\n" \
      "platform: linux/amd64\n" \
      "container: not persisted (persist is off); none in flight\n"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "container status renders the image line: #{description}" do
    Given "an image #{description}"
    status = status(local: local, registry: registry, containers: [])

    Expect
    status_output(status, persist: true).lines.first == "image: myapp-linux — #{TAG} — #{rendered}\n"

    Where
    description                      | local | registry | rendered
    "local and published"            | true  | true     | "local, in registry"
    "local only"                     | true  | false    | "local, not in registry"
    "published, not pulled"          | false | true     | "in registry, not local (dev container up pulls it)"
    "nowhere"                        | false | false    | "not built (dev container up builds it)"
    "local, registry unknown"        | true  | nil      | "local, registry unknown (gh auth login)"
    "nowhere known"                  | false | nil      | "not local, registry unknown (gh auth login)"
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
    "running, on this user's prefix volume" | [[CURRENT, true, "dev-linuxbrew-jp"]]            | ["container: #{CURRENT} — running, prefix dev-linuxbrew-jp\n"]
    "stopped, on this user's prefix volume" | [[CURRENT, false, "dev-linuxbrew-jp"]]           | ["container: #{CURRENT} — stopped, prefix dev-linuxbrew-jp (dev container up restarts it warm)\n"]
    "stopped, on the legacy prefix volume"  | [[CURRENT, false, "dev-linuxbrew"]]              | ["container: #{CURRENT} — stopped, prefix dev-linuxbrew — not this user's, dev-linuxbrew-jp (dev container up recreates it)\n"]
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
    "nothing"        | []                        | ["container: not persisted (persist is off); none in flight\n"]
    "a run going"    | [["dev-myapp-x", true]]   | ["container: not persisted (persist is off); in flight: dev-myapp-x\n"]
  end

  private

  def client
    Dev::BuildContainer.new(engine: FakeContainerEngine.new)
  end

  # An aligner that finds the container's user already able to write the data root.
  def aligned_user
    aligner = typed_mock(Dev::ContainerUserAligner)
    aligner.stubs(:align!).returns(:aligned)
    aligner
  end

  def config(persist:, volumes: [], build_args: {}, build_secrets: {})
    Dev::BuildContainerConfig.new(
      image: "myapp-linux", registry: "myregistry", persist: persist, volumes: volumes,
      build_args: build_args, build_secrets: build_secrets,
    )
  end

  # A project context; a legacy block comes with its key recorded, as the
  # loader records it.
  def project(build_container, root: ROOT, engine: nil)
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui),
      project: Dev::ProjectContext.new(
        name: "TestProject", root: root, engine: engine, build_container: build_container,
        legacy_keys: build_container ? ["build.container"] : [],
      ),
    )
  end

  # A real checkout root whose Dockerfile declares the environment's platform.
  def project_root_declaring(docker_platform)
    root = Pathname(Dir.mktmpdir("container-commands"))
    (root / "Dockerfile").write("FROM --platform=#{docker_platform} ubuntu:22.04\n")
    root
  end

  # A real checkout root whose lock pins its images (dev#277), each on that
  # platform unless its metadata says otherwise; one `myapp-linux` by default.
  def project_root_pinning(docker_platform, images: { "myapp-linux" => {} })
    root = Pathname(Dir.mktmpdir("container-commands"))
    pins = images.map do |name, metadata|
      platform = metadata.fetch("platform", docker_platform)
      Dev::Deps::Dependency.new(
        name: name, integration: :image, group: :app, version: "ue5.8-3", hash: "SHA256=#{"a" * 64}",
        metadata: {
          "from" => "ghcr.io/d3mlabs/unreal-engine-build-base", "platform" => platform,
          "platforms" => [platform], "registry" => "ghcr.io/d3mlabs", "apt" => [],
        }.merge(metadata),
      )
    end
    Dev::Deps::Lockfile.new(dir: root).lock(Dev::EnvironmentImage.stamp(pins))
    root
  end

  # The host rule over a marker (absent by default) and a platform.
  def rule(host_platform, marker: nil)
    path = marker || "/nonexistent/dev-environment-marker"
    Dev::HostRule.new(host_environment: Dev::HostEnvironment.new(path: path), host_platform: host_platform)
  end

  # Write under +root+ the marker a host provisioned from +image+ carries.
  def marker_for(root, image)
    path = root / "etc-dev-environment"
    path.write(image.marker)
    path.to_s
  end

  def pinned(root)
    Dev::Deps::Lockfile.new(dir: root).read.select { |pin| pin.integration == :image }
      .map { |pin| Dev::EnvironmentImage.from_pin(pin) }
  end

  def status(local:, registry:, containers:)
    Dev::BuildContainer::ServiceStatus.new(
      image_tag: TAG, local_image: local, in_registry: registry, current_container_name: CURRENT,
      containers: containers.map { |name, running, prefix_volume| Dev::BuildContainer::ServiceContainer.new(name:, running:, prefix_volume:) },
    )
  end

  def status_output(status, persist:)
    config = config(persist: persist)
    client = client()
    Dev::BuildContainer.stubs(:image_with_tag).with(config, project_root: ROOT).returns(TAG)
    client.stubs(:service_status).with(TAG, ROOT, registry: nil).returns(status)
    client.stubs(:prefix_volume).returns("dev-linuxbrew-jp")
    out = StringIO.new
    Dev::Builtins::ContainerStatusCommand.new(container_client: client, out: out).call(args: no_args, context: project(config))
    out.string
  end
end

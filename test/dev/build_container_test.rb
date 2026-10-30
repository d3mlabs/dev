# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/build_container"
require "dev/engine_resources_check"
require "support/fake_container_engine"
require "support/fake_registry_login"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class BuildContainerTest < Minitest::Test
  include SorbetHelper

  # Engine-injected instance under test: the docker CLI is a true boundary,
  # so the fake engine records argv instead of tests stubbing Kernel#system.
  # A Mac unless said otherwise: the data root's shape is the host OS's,
  # and these tests run on either.
  def build_container(engine: FakeContainerEngine.new, host_os: "darwin", host_user: "jp")
    Dev::BuildContainer.new(engine: engine, host_os: host_os, host_user: host_user)
  end

  test "the Linuxbrew prefix volume is per host user on Linux and per VM on a Mac: one owner per prefix" do
    Expect
    Dev::BuildContainer.prefix_volume(host_os: "linux", host_user: "runner") == "dev-linuxbrew-runner"
    Dev::BuildContainer.prefix_volume(host_os: "linux", host_user: "jpduchesne") == "dev-linuxbrew-jpduchesne"
    Dev::BuildContainer.prefix_volume(host_os: "darwin", host_user: "jp") == "dev-linuxbrew"
    Dev::BuildContainer.prefix_volume(host_os: "linux") == "dev-linuxbrew-#{Dev::BuildContainer.host_user}"
    !Dev::BuildContainer.host_user.empty?
  end

  def service(name, running:)
    Dev::BuildContainer::ServiceContainer.new(name: name, running: running)
  end

  # A method, not a block: RSpock's source rewrite gives one-parameter
  # blocks a trailing comma, which splats an Array argument.
  def detached_run?(args)
    args.first(2) == ["run", "-d"]
  end

  test "docker_run_command produces correct command array" do
    When "building a docker run command"
    cmd = build_container.docker_run_command(
      "jpduchesne89/snappy:content-abc123",
      project_root: Pathname("/project"),
      shell_cmd: "./bin/build.sh",
    ).argv

    Then
    cmd[0] == "docker"
    cmd[1] == "run"
    cmd.include?("--rm")
    cmd.include?("-v")
    cmd.include?("/project:/project")
    cmd.last(3) == ["sh", "-c", "./bin/build.sh"]
  end

  test "docker_run_command widens the pending-signal ulimit (Rosetta pend_signal aborts)" do
    When "building a docker run command"
    cmd = build_container.docker_run_command(
      "jpduchesne89/snappy:content-abc123",
      project_root: Pathname("/project"),
      shell_cmd: "./bin/build.sh",
    ).argv

    Then "the run carries the widened sigpending bucket"
    cmd.include?("sigpending=1000000")
    cmd[cmd.index("sigpending=1000000") - 1] == "--ulimit"
  end

  test "docker_run_command renders extra volume mounts" do
    When "building a docker run command with volumes"
    cmd = build_container.docker_run_command(
      "jpduchesne89/snappy:content-abc123",
      project_root: Pathname("/project"),
      shell_cmd: "./bin/build.sh",
      volumes: ["/opt/engines/ue:/ue", "/var/cache/wwise:/wwise"],
    ).argv

    Then
    cmd.include?("/opt/engines/ue:/ue")
    cmd.include?("/var/cache/wwise:/wwise")
    cmd[cmd.index("/opt/engines/ue:/ue") - 1] == "-v"
    cmd[cmd.index("/var/cache/wwise:/wwise") - 1] == "-v"
    cmd.index("-w") > cmd.index("/var/cache/wwise:/wwise")
  end

  test "docker_run_command names env vars with bare -e flags and carries their values in the invocation's env, never on argv (dev#317)" do
    When "building a docker run command with env"
    invocation = build_container.docker_run_command(
      "jpduchesne89/snappy:content-abc123",
      project_root: Pathname("/project"),
      shell_cmd: "./bin/build.sh",
      env: { "WWISE_TOKEN" => "tok-123" },
    )
    cmd = invocation.argv

    Then "argv says -e WWISE_TOKEN (docker reads the value from the client's env) before -w; the value is in env only"
    cmd.each_cons(2).include?(["-e", "WWISE_TOKEN"])
    cmd.index("-w") > cmd.index("WWISE_TOKEN")
    cmd.none? { |part| part.include?("tok-123") }
    invocation.env["WWISE_TOKEN"] == "tok-123"
  end

  test "docker_run_command marks the container as inside so the dev it runs knows where it is" do
    When "building a one-shot run with its own env"
    invocation = build_container.docker_run_command(
      "jpduchesne89/snappy:content-abc123",
      project_root: Pathname("/project"),
      shell_cmd: "./bin/build.sh",
      env: { "WWISE_TOKEN" => "tok-123" },
    )
    cmd = invocation.argv

    Then "DEV_INSIDE_CONTAINER rides -e beside the configured env, before the image; both values in the env"
    cmd.each_cons(2).include?(["-e", "DEV_INSIDE_CONTAINER"])
    cmd.each_cons(2).include?(["-e", "WWISE_TOKEN"])
    cmd.index("DEV_INSIDE_CONTAINER") < cmd.index("jpduchesne89/snappy:content-abc123")
    invocation.env.slice("DEV_INSIDE_CONTAINER", "WWISE_TOKEN") == { "DEV_INSIDE_CONTAINER" => "1", "WWISE_TOKEN" => "tok-123" }
  end

  test "docker_run_command mounts the container's own data root volumes, never the host's directory (ADR-0008)" do
    Given "a host data root that must not leak into the container"
    root = Dir.mktmpdir("dev-data-root")
    original = ENV["DEV_DATA_ROOT"]
    ENV["DEV_DATA_ROOT"] = root
    engine = FakeContainerEngine.new

    When "building a one-shot run"
    invocation = build_container(engine: engine).docker_run_command(
      "jpduchesne89/snappy:content-abc123",
      project_root: Pathname("/project"),
      shell_cmd: "./bin/build.sh",
    )
    cmd = invocation.argv

    Then "both volumes are created first (docker volume create is idempotent), mounted at the data root and the Linuxbrew prefix before the image, DEV_DATA_ROOT names the mount, and the host's directory appears nowhere"
    engine.runs.include?(["volume", "create", "dev-data-root"])
    engine.runs.include?(["volume", "create", "dev-linuxbrew"])
    cmd.each_cons(2).include?(["-v", "dev-data-root:/var/lib/dev"])
    cmd.each_cons(2).include?(["-v", "dev-linuxbrew:/home/linuxbrew/.linuxbrew"])
    cmd.index("dev-data-root:/var/lib/dev") < cmd.index("jpduchesne89/snappy:content-abc123")
    cmd.each_cons(2).include?(["-e", "DEV_DATA_ROOT"])
    invocation.env["DEV_DATA_ROOT"] == "/var/lib/dev"
    cmd.none? { |part| part.include?(root) }
    invocation.env.values.none? { |value| value.include?(root) }

    Cleanup
    ENV["DEV_DATA_ROOT"] = original
    FileUtils.rm_rf(root)
  end

  test "on Linux, #{what} bind-mounts the host's data root at its own path — one store, both sides (dev#308)" do
    Given "a Linux host whose data root is #{root_kind}"
    root = Dir.mktmpdir("linux-data-root")
    original = ENV["DEV_DATA_ROOT"]
    ENV["DEV_DATA_ROOT"] = root
    engine = FakeContainerEngine.new
    bc = build_container(engine: engine, host_os: "linux")

    When
    cmd, env = if what == "docker_run_command"
      invocation = bc.docker_run_command("ghcr.io/d3mlabs/snappy-linux:abc", project_root: Pathname("/project"), shell_cmd: "./bin/build.sh")
      [invocation.argv, invocation.env]
    else
      bc.send(:create_service_container, "svc", "ghcr.io/d3mlabs/snappy-linux:abc", project_root: Pathname("/project"))
      index = engine.runs.index(&method(:detached_run?))
      [engine.runs.fetch(index), engine.run_envs.fetch(index)]
    end

    Then "the host's root at the host's path, DEV_DATA_ROOT agreeing; no data-root volume; Linuxbrew still a volume — the host user's own (brew is single-owner, and the engine is shared by the host's users)"
    cmd.each_cons(2).include?(["-v", "#{root}:#{root}"])
    cmd.each_cons(2).include?(["-e", "DEV_DATA_ROOT"])
    env["DEV_DATA_ROOT"] == root
    cmd.each_cons(2).include?(["-v", "dev-linuxbrew-jp:/home/linuxbrew/.linuxbrew"])
    cmd.none? { |part| part.include?("dev-data-root") }
    !engine.runs.include?(["volume", "create", "dev-data-root"])
    engine.runs.include?(["volume", "create", "dev-linuxbrew-jp"])
    cmd.count { |part| part == "-v" } == 3

    Cleanup
    ENV["DEV_DATA_ROOT"] = original
    FileUtils.rm_rf(root)

    Where
    what                       | root_kind
    "docker_run_command"       | "the override"
    "create_service_container" | "the override"
  end

  test "on Linux with the default root, the mount is /var/lib/dev on both sides" do
    Given
    original = ENV["DEV_DATA_ROOT"]
    ENV.delete("DEV_DATA_ROOT")
    Dev::Platform.stubs(:os).returns("linux")

    When
    invocation = build_container(host_os: "linux").docker_run_command(
      "ghcr.io/d3mlabs/snappy-linux:abc", project_root: Pathname("/project"), shell_cmd: "./bin/build.sh",
    )

    Then
    invocation.argv.each_cons(2).include?(["-v", "/var/lib/dev:/var/lib/dev"])
    invocation.argv.each_cons(2).include?(["-e", "DEV_DATA_ROOT"])
    invocation.env["DEV_DATA_ROOT"] == "/var/lib/dev"

    Cleanup
    ENV["DEV_DATA_ROOT"] = original if original
  end

  test "docker_run_command expands ~ in volume host paths, re-rooting ~/.dev onto the data root" do
    Given "a scratch data root"
    root = Dir.mktmpdir("bc-data-root-")
    original = ENV["DEV_DATA_ROOT"]
    ENV["DEV_DATA_ROOT"] = root

    When "building a docker run command with a ~ volume"
    cmd = build_container.docker_run_command(
      "jpduchesne89/snappy:content-abc123",
      project_root: Pathname("/project"),
      shell_cmd: "./bin/build.sh",
      volumes: ["~/.dev/engines/unreal-engine-css:/ue"],
    ).argv

    Then
    cmd.include?("#{File.join(root, "engines/unreal-engine-css")}:/ue")
    !cmd.any? { |part| part.start_with?("~") }

    Cleanup
    ENV["DEV_DATA_ROOT"] = original
    FileUtils.rm_rf(root)
  end

  test "docker_run_command carries the engine's argv prefix" do
    Given "an engine whose docker rides a custom prefix"
    engine = FakeContainerEngine.new
    engine.instance_variable_set(:@argv_prefix, ["docker", "--context", "remote"])

    When "building a docker run command"
    cmd = build_container(engine: engine).docker_run_command(
      "img:tag", project_root: Pathname("/project"), shell_cmd: "true",
    ).argv

    Then "the prefix leads the argv"
    cmd[0, 3] == ["docker", "--context", "remote"]
    cmd[3] == "run"
  end

  test "mount composition refuses an engine without local mounts (the remote-poisoned assumption, named)" do
    Given "an engine whose daemon cannot see local paths"
    bc = build_container(engine: FakeContainerEngine.new(local_mounts: false))

    When "composing a run command (which always mounts the project)"
    bc.docker_run_command("img:tag", project_root: Pathname("/project"), shell_cmd: "true")

    Then
    raises Dev::BuildContainer::LocalMountsUnsupportedError
  end

  test "publish! is a no-op when the registry already advertises the tag" do
    Given "the instance under test"
    bc = build_container

    When "publishing a tag the registry already has"
    result = bc.publish!("img:tag")

    Then "the manifest check short-circuits and nothing is pushed"
    result == true
    1 * bc.registry_has?("img:tag") >> true
    0 * bc.push!("img:tag")
  end

  test "publish! pushes when the registry lacks the tag" do
    Given "the instance under test"
    bc = build_container

    When "publishing a tag the registry lacks"
    result = bc.publish!("img:tag")

    Then "it pushes the local image"
    result == true
    1 * bc.registry_has?("img:tag") >> false
    1 * bc.push!("img:tag") >> true
  end

  test "publish! warns but does not raise when the push fails" do
    Given "the instance under test"
    bc = build_container

    When "the registry lacks the tag and the push fails"
    result = bc.publish!("img:tag")

    Then "the failure is surfaced as a falsey return, not an exception"
    result == false
    1 * bc.registry_has?("img:tag") >> false
    1 * bc.push!("img:tag") >> false
  end

  test "service_container_name keys the name by image, workspace, and tag" do
    Given "a full image:tag and the checkout it runs in"
    root = Pathname("/work/snappy")
    wid = Dev::BuildContainer.workspace_id(root)

    When "naming the service container"
    name = Dev::BuildContainer.service_container_name("jpduchesne89/snappy-linux:content-abc123", root)

    Then "the name is registry-free, colon-free, dev-prefixed, and workspace-keyed"
    name == "dev-snappy-linux-#{wid}-content-abc123"
  end

  test "service_container_name differs per checkout for the same image tag" do
    Given "one image:tag checked out in two directories"
    tag = "jpduchesne89/snappy-linux:content-abc123"

    When "naming the service container for each checkout"
    runner = Dev::BuildContainer.service_container_name(tag, Pathname("/runner/_work/snappy/snappy"))
    manual = Dev::BuildContainer.service_container_name(tag, Pathname("/home/dev/snappy"))

    Then "the names differ, so neither checkout can hijack the other's container"
    runner != manual
  end

  test "docker_exec_command targets the container with /project workdir" do
    When "building a docker exec command"
    cmd = build_container.docker_exec_command(
      "dev-snappy-linux-content-abc", shell_cmd: "./bin/build.sh",
    ).argv

    Then
    cmd[0] == "docker"
    cmd[1] == "exec"
    cmd.include?("-w")
    cmd.include?("/project")
    cmd.include?("dev-snappy-linux-content-abc")
    cmd.last(3) == ["sh", "-c", "./bin/build.sh"]
  end

  test "docker_exec_command names env vars with bare -e flags before the container; the values ride the invocation's env, never argv (dev#317)" do
    When "building a docker exec command with env"
    invocation = build_container.docker_exec_command(
      "dev-snappy-linux-content-abc", shell_cmd: "./bin/build.sh",
      env: { "WWISE_TOKEN" => "tok-123" },
    )
    cmd = invocation.argv

    Then "the -e flag precedes the container name (a docker exec arg-order rule); the value is in env only"
    cmd.each_cons(2).include?(["-e", "WWISE_TOKEN"])
    cmd.index("WWISE_TOKEN") < cmd.index("dev-snappy-linux-content-abc")
    cmd.none? { |part| part.include?("tok-123") }
    invocation.env == { "WWISE_TOKEN" => "tok-123" }
  end

  test "ensure_service! creates the container when none exists" do
    Given "an image tag whose container is absent, and the checkout it runs in"
    tag = "jpduchesne89/snappy-linux:content-abc"
    root = Pathname("/proj")
    name = Dev::BuildContainer.service_container_name(tag, root)
    bc = build_container

    When "ensuring the service"
    result = bc.ensure_service!(tag, project_root: root, volumes: ["/e:/e"])

    Then "stale containers are reaped, then the container is created (never started)"
    result == name
    1 * bc.reap_stale_services!(tag, root) >> nil
    1 * bc.container_exists?(name) >> false
    1 * bc.create_service_container(name, tag,
      project_root: root, volumes: ["/e:/e"]) >> true
    0 * bc.start_container(name)
  end

  test "ensure_service! starts the container when it exists but is stopped" do
    Given "an image tag whose container exists but is stopped"
    tag = "jpduchesne89/snappy-linux:content-abc"
    root = Pathname("/proj")
    name = Dev::BuildContainer.service_container_name(tag, root)
    bc = build_container

    When "ensuring the service"
    bc.ensure_service!(tag, project_root: root)

    Then "the existing container, on this user's prefix volume, is started, not recreated"
    1 * bc.reap_stale_services!(tag, root) >> nil
    1 * bc.container_exists?(name) >> true
    1 * bc.container_prefix_volume(name) >> "dev-linuxbrew"
    1 * bc.container_running?(name) >> false
    1 * bc.start_container(name) >> true
    0 * bc.create_service_container(name, tag,
      project_root: root, volumes: [])
  end

  test "ensure_service! is a no-op when the container is already running" do
    Given "an image tag whose container is already up"
    tag = "jpduchesne89/snappy-linux:content-abc"
    root = Pathname("/proj")
    name = Dev::BuildContainer.service_container_name(tag, root)
    bc = build_container

    When "ensuring the service"
    bc.ensure_service!(tag, project_root: root)

    Then "neither start nor create is invoked"
    1 * bc.reap_stale_services!(tag, root) >> nil
    1 * bc.container_exists?(name) >> true
    1 * bc.container_prefix_volume(name) >> "dev-linuxbrew"
    1 * bc.container_running?(name) >> true
    0 * bc.start_container(name)
  end

  # A container's mounts are fixed at creation. One created before the
  # per-user split mounts the bare `dev-linuxbrew`; reused, it would have
  # this user's aligner hand that shared volume over — and the other user's
  # hand it back. The container is this checkout's to recreate.
  test "ensure_service! recreates a container that mounts another prefix volume than this user's: #{what}" do
    Given "a container on #{mounted.inspect}, this user's volume being dev-linuxbrew-jp (Linux)"
    tag = "jpduchesne89/snappy-linux:content-abc"
    root = Pathname("/proj")
    name = Dev::BuildContainer.service_container_name(tag, root)
    bc = build_container(host_os: "linux")

    When
    bc.ensure_service!(tag, project_root: root)

    Then
    1 * bc.reap_stale_services!(tag, root) >> nil
    1 * bc.container_exists?(name) >> true
    1 * bc.container_prefix_volume(name) >> mounted
    recreated * bc.remove_container(name) >> true
    recreated * bc.create_service_container(name, tag, project_root: root, volumes: []) >> true
    reused * bc.container_running?(name) >> true

    Where
    what                        | mounted                   | recreated | reused
    "the legacy shared volume"  | "dev-linuxbrew"           | 1         | 0
    "another user's"            | "dev-linuxbrew-runner"    | 1         | 0
    "its own"                   | "dev-linuxbrew-jp"        | 0         | 1
    "unknown (inspect failed)"  | nil                       | 0         | 1
  end

  test "container_prefix_volume reads the volume mounted at the Linuxbrew prefix; nil when inspect says nothing" do
    Given
    engine = FakeContainerEngine.new(capture_result: ->(args) { args.first == "container" ? "dev-linuxbrew-runner\n" : "" })

    Expect
    build_container(engine: engine).container_prefix_volume("dev-x") == "dev-linuxbrew-runner"
    engine.captures.last == ["container", "inspect", "-f", "{{range .Mounts}}{{if eq .Destination \"/home/linuxbrew/.linuxbrew\"}}{{.Name}}{{end}}{{end}}", "dev-x"]
    build_container(engine: FakeContainerEngine.new).container_prefix_volume("dev-x").nil?
  end

  test "reap_stale_services! removes other-tag containers but keeps the current tag" do
    Given "a current tag and a stale sibling container in the same checkout"
    tag = "jpduchesne89/snappy-linux:content-new"
    root = Pathname("/proj")
    keep = service(Dev::BuildContainer.service_container_name(tag, root), running: true)
    stale = service(Dev::BuildContainer.service_container_name("jpduchesne89/snappy-linux:content-old", root),
      running: false)
    bc = build_container

    When "reaping"
    bc.reap_stale_services!(tag, root)

    Then "only the non-current container is removed"
    1 * bc.service_containers(root) >> [stale, keep]
    1 * bc.remove_container(stale.name) >> true
    0 * bc.remove_container(keep.name)
  end

  test "reset_service! removes every container for the checkout" do
    Given "two containers for the checkout (current and stale)"
    root = Pathname("/proj")
    current = service("dev-snappy-linux-abc-content-abc", running: true)
    stale = service("dev-snappy-linux-abc-content-old", running: false)
    bc = build_container

    When "resetting"
    result = bc.reset_service!(root)

    Then "all of the checkout's containers are removed and their names returned"
    result == [stale.name, current.name]
    1 * bc.service_containers(root) >> [stale, current]
    1 * bc.remove_container(stale.name) >> true
    1 * bc.remove_container(current.name) >> true
  end

  test "stop_service! stops the checkout's running containers with no grace period, keeping them" do
    Given "a running and a stopped container for the checkout"
    root = Pathname("/proj")
    running = service("dev-snappy-linux-abc-content-abc", running: true)
    stopped = service("dev-snappy-linux-abc-content-old", running: false)
    engine = FakeContainerEngine.new
    bc = build_container(engine: engine)
    bc.stubs(:service_containers).with(root).returns([stopped, running])

    When "stopping"
    result = bc.stop_service!(root)

    Then "only the running one is stopped (-t 0: PID 1 is sleep, which ignores SIGTERM); nothing is removed"
    result == [running.name]
    engine.runs == [["stop", "-t", "0", running.name]]
  end

  test "stop_service! raises when a container will not stop" do
    Given "a running container whose stop fails"
    root = Pathname("/proj")
    bc = build_container(engine: FakeContainerEngine.new { |_args| false })
    bc.stubs(:service_containers).returns([service("dev-x", running: true)])

    When "stopping"
    bc.stop_service!(root)

    Then
    error = raises Dev::BuildContainer::StopFailedError
    error.message == "could not stop container dev-x."
  end

  test "stop_service! on a checkout with nothing running returns no names" do
    Given "no containers for the checkout"
    engine = FakeContainerEngine.new(capture_result: "")
    bc = build_container(engine: engine)

    Expect "nothing stopped, nothing run"
    bc.stop_service!(Pathname("/proj")) == []
    engine.runs == []
  end

  test "service_status gathers image presence and the checkout's containers" do
    Given "a local image, a registry copy, and a current + stale container"
    tag = "jpduchesne89/snappy-linux:content-abc"
    root = Pathname("/proj")
    current = service(Dev::BuildContainer.service_container_name(tag, root), running: true)
    stale = service(Dev::BuildContainer.service_container_name("jpduchesne89/snappy-linux:content-old", root), running: false)
    bc = Dev::BuildContainer.new(engine: FakeContainerEngine.new, registry_login: FakeRegistryLogin.new)
    bc.stubs(:local_image?).with(tag).returns(true)
    bc.stubs(:registry_has?).with(tag).returns(false)
    bc.stubs(:service_containers).with(root).returns([stale, current])

    When "reporting"
    status = bc.service_status(tag, root, registry: "docker.io")

    Then "one record, the current container named so the renderer can tell it from stale ones"
    status.image_tag == tag
    status.local_image == true
    status.in_registry == false
    status.current_container_name == current.name
    status.containers == [stale, current]
  end

  test "reap_stale_services! and service_status keep to the image's own containers: another image's are not stale siblings (dev#307)" do
    Given "a checkout with two persisted images, each with a container, and a stale one of the first"
    root = Pathname("/proj")
    linux = "ghcr.io/d3mlabs/snappy-linux:aaaa"
    server = "ghcr.io/d3mlabs/snappy-server:bbbb"
    linux_current = service(Dev::BuildContainer.service_container_name(linux, root), running: true)
    linux_stale = service(Dev::BuildContainer.service_container_name("ghcr.io/d3mlabs/snappy-linux:0000", root), running: false)
    server_current = service(Dev::BuildContainer.service_container_name(server, root), running: true)
    bc = Dev::BuildContainer.new(engine: FakeContainerEngine.new, registry_login: FakeRegistryLogin.new)
    bc.stubs(:service_containers).with(root).returns([linux_stale, linux_current, server_current])
    bc.stubs(:local_image?).returns(true)
    bc.stubs(:registry_has?).returns(true)

    When "reaping for the first image, and reporting on it"
    bc.reap_stale_services!(linux, root)
    status = bc.service_status(linux, root, registry: "ghcr.io")

    Then "only the first image's stale container goes; the report lists the first image's containers alone"
    1 * bc.remove_container(linux_stale.name) >> true
    0 * bc.remove_container(server_current.name)
    status.containers == [linux_stale, linux_current]
  end

  test "service_status probes the registry inside a login session when told the registry: read scope, the probe, logout (dev#313)" do
    Given "a pinned image on a private registry, and a recording login"
    tag = "ghcr.io/d3mlabs/snappy-linux:aaaa"
    root = Pathname("/proj")
    login = FakeRegistryLogin.new
    bc = Dev::BuildContainer.new(engine: FakeContainerEngine.new, registry_login: login)
    bc.stubs(:local_image?).with(tag).returns(false)
    bc.stubs(:registry_has?).with(tag).returns(true)
    bc.stubs(:service_containers).with(root).returns([])

    When
    status = bc.service_status(tag, root, registry: "ghcr.io")

    Then "the registry's answer, asked from inside the session"
    status.in_registry == true
    login.sessions == [["ghcr.io", false]]
  end

  test "service_status without a credential to ask with leaves the registry half unknown rather than claiming absence (dev#313)" do
    Given "a host with no gh auth: the login refuses with #{error}"
    tag = "ghcr.io/d3mlabs/snappy-linux:aaaa"
    root = Pathname("/proj")
    login = FakeRegistryLogin.new
    login.stubs(:with).raises(error, "no")
    bc = Dev::BuildContainer.new(engine: FakeContainerEngine.new, registry_login: login)
    bc.stubs(:local_image?).with(tag).returns(true)
    bc.stubs(:service_containers).with(root).returns([])

    When
    status = bc.service_status(tag, root, registry: "ghcr.io")

    Then "the local half is still answered; the registry half is nil"
    status.local_image == true
    status.in_registry.nil?
    0 * bc.registry_has?(tag)

    Where
    error                                   | _
    Dev::GhAuth::NotAuthenticatedError      | nil
    Dev::GhAuth::MissingScopeError          | nil
    Dev::GhAuth::GhMissingError             | nil
    Dev::RegistryLogin::LoginFailedError    | nil
  end

  test "create_service_container runs detached, mounts project + volumes, idles, and carries the label contract" do
    Given "a recording engine and the checkout's labels"
    engine = FakeContainerEngine.new
    root = Pathname("/project")
    labels = Dev::BuildContainer.service_labels("img:tag", root)

    When "creating the service container"
    build_container(engine: engine).create_service_container(
      "dev-x", "img:tag",
      project_root: root, volumes: ["/engines/ue:/ue"],
    )

    Then "it is a detached, named run that bind-mounts the project + engine and sleeps"
    engine.runs.last[0, 4] == ["run", "-d", "--name", "dev-x"]
    engine.runs.last.include?("/project:/project")
    engine.runs.last.include?("/engines/ue:/ue")
    engine.runs.last.include?("img:tag")
    engine.runs.last.last(2) == ["sleep", "infinity"]
    labels.all? { |key, value| engine.runs.last.each_cons(2).include?(["--label", "#{key}=#{value}"]) }
  end

  test "create_service_container marks the container as inside, so every later docker exec inherits it" do
    Given "a recording engine"
    engine = FakeContainerEngine.new

    When "creating the service container"
    build_container(engine: engine).create_service_container(
      "dev-x", "img:tag", project_root: Pathname("/project"), volumes: [],
    )

    Then "the detached run names DEV_INSIDE_CONTAINER before the image; its value rides the run's env"
    run = engine.runs.last
    run.each_cons(2).include?(["-e", "DEV_INSIDE_CONTAINER"])
    run.index("DEV_INSIDE_CONTAINER") < run.index("img:tag")
    engine.run_envs.last["DEV_INSIDE_CONTAINER"] == "1"
  end

  test "create_service_container mounts the same two volumes as a one-shot run, so a recreated container finds its data root warm" do
    Given "a recording engine and a host data root that must not leak in"
    engine = FakeContainerEngine.new
    root = Dir.mktmpdir("dev-data-root")
    original = ENV["DEV_DATA_ROOT"]
    ENV["DEV_DATA_ROOT"] = root

    When "creating the service container"
    build_container(engine: engine).create_service_container(
      "dev-x", "img:tag", project_root: Pathname("/project"), volumes: [],
    )

    Then "the detached run mounts both volumes, sets DEV_DATA_ROOT, and names no host path"
    run = engine.runs.last
    run.each_cons(2).include?(["-v", "dev-data-root:/var/lib/dev"])
    run.each_cons(2).include?(["-v", "dev-linuxbrew:/home/linuxbrew/.linuxbrew"])
    run.each_cons(2).include?(["-e", "DEV_DATA_ROOT"])
    engine.run_envs.last["DEV_DATA_ROOT"] == "/var/lib/dev"
    run.none? { |part| part.include?(root) }

    Cleanup
    ENV["DEV_DATA_ROOT"] = original
    FileUtils.rm_rf(root)
  end

  test "docker_run_command carries the label contract so dev engine down recognizes an in-flight --rm run" do
    Given "the checkout's labels"
    root = Pathname("/project")
    labels = Dev::BuildContainer.service_labels("img:tag", root)

    When "building a one-shot run"
    cmd = build_container.docker_run_command("img:tag", project_root: root, shell_cmd: "make").argv

    Then "every label precedes the image"
    labels.all? { |key, value| cmd.each_cons(2).include?(["--label", "#{key}=#{value}"]) }
    cmd.index("--label") < cmd.index("img:tag")
  end

  test "service_labels is the contract dev reads back: managed, the checkout's real path and name, workspace id, image" do
    Given "a checkout reached through a symlink"
    dir = Dir.mktmpdir("build-container-labels-")
    real = File.realpath(dir)
    link = File.join(Dir.mktmpdir("build-container-link-"), "snappy")
    File.symlink(real, link)
    root = Pathname(link)

    When "computing the labels"
    labels = Dev::BuildContainer.service_labels("reg/snappy-linux:content-abc", root)

    Then "they resolve the symlink, so one checkout has one identity however it is reached"
    labels == {
      Dev::ContainerEngine::MANAGED_LABEL => "true",
      Dev::ContainerEngine::PROJECT_ROOT_LABEL => real,
      Dev::BuildContainer::PROJECT_LABEL => File.basename(real),
      Dev::BuildContainer::WORKSPACE_LABEL => Dev::BuildContainer.workspace_id(root),
      Dev::BuildContainer::IMAGE_LABEL => "reg/snappy-linux:content-abc",
    }

    Cleanup
    FileUtils.rm_rf(dir)
    FileUtils.rm_rf(File.dirname(link))
  end

  test "create_service_container raises when docker run fails" do
    Given "an engine whose runs fail"
    engine = FakeContainerEngine.new { |_args| false }

    When "docker run fails"
    build_container(engine: engine).create_service_container(
      "dev-x", "img:tag", project_root: Pathname("/project"),
    )

    Then
    raises RuntimeError
  end

  test "with_one_shot_container creates a --rm sibling of the service container, yields its name, and removes it after" do
    Given "a recording engine"
    engine = FakeContainerEngine.new
    root = Pathname("/project")
    service_name = Dev::BuildContainer.service_container_name("img:tag", root)
    seen = {}

    When "running a block in a one-shot container"
    build_container(engine: engine).with_one_shot_container("img:tag", project_root: root, volumes: ["/e:/ue"]) do |name|
      seen[:name] = name
      seen[:runs_so_far] = engine.runs.size
    end

    Then "the name is the service's plus a cold suffix, the run is detached and --rm with the same mounts and labels, and rm -f follows the block"
    seen[:name].start_with?("#{service_name}-cold-")
    seen[:name] != service_name
    engine.runs[0, 2] == [["volume", "create", "dev-data-root"], ["volume", "create", "dev-linuxbrew"]]
    create = engine.runs.fetch(2)
    create[0, 2] == ["run", "-d"]
    create.include?("--rm")
    create.each_cons(2).include?(["--name", seen[:name]])
    create.include?("/project:/project")
    create.include?("/e:/ue")
    create.each_cons(2).include?(["-e", "DEV_INSIDE_CONTAINER"])
    engine.run_envs.fetch(2)["DEV_INSIDE_CONTAINER"] == "1"
    create.last(2) == ["sleep", "infinity"]
    Dev::BuildContainer.service_labels("img:tag", root).all? { |k, v| create.each_cons(2).include?(["--label", "#{k}=#{v}"]) }
    seen[:runs_so_far] == 3
    engine.runs.last == ["rm", "-f", seen[:name]]
  end

  test "with_one_shot_container removes the container even when the block raises" do
    Given "a recording engine"
    engine = FakeContainerEngine.new
    seen = {}

    When "the block fails"
    begin
      build_container(engine: engine).with_one_shot_container("img:tag", project_root: Pathname("/project")) do |name|
        seen[:name] = name
        raise "install exploded"
      end
    rescue RuntimeError
      nil
    end

    Then "rm -f still ran"
    engine.runs.last == ["rm", "-f", seen[:name]]
  end

  test "with_one_shot_container raises when the container cannot be created, and runs no block" do
    Given "an engine whose runs fail"
    engine = FakeContainerEngine.new { |_args| false }
    ran = false

    When "creating"
    build_container(engine: engine).with_one_shot_container("img:tag", project_root: Pathname("/project")) { |_name| ran = true }

    Then
    raises RuntimeError
    ran == false
  end

  test "the docker CLI wrappers compose their args through the engine and pass its success through" do
    Given "an engine whose every invocation succeeds"
    engine = FakeContainerEngine.new
    bc = build_container(engine: engine)

    When "invoking every one-command wrapper"
    exists = bc.container_exists?("dev-x")
    bc.start_container("dev-x")
    bc.remove_container("dev-x")
    local = bc.local_image?("img:tag")
    pulled = bc.pull("img:tag")
    pushed = bc.push!("img:tag")
    advertised = bc.registry_has?("img:tag")

    Then "each predicate reports the engine's success, and the recorded argv names each docker subcommand"
    exists && local && pulled && pushed && advertised
    engine.runs == [
      ["container", "inspect", "dev-x"],
      ["start", "dev-x"],
      ["rm", "-f", "dev-x"],
      ["image", "inspect", "img:tag"],
      ["pull", "img:tag"],
      ["push", "img:tag"],
      ["manifest", "inspect", "img:tag"],
    ]
  end

  test "service_containers lists the checkout's containers by workspace label, running or not" do
    Given "docker ps reporting a running and an exited container, with surrounding noise"
    root = Pathname("/proj")
    volumes = { "dev-snappy-abc-content-1" => "dev-linuxbrew-jp\n", "dev-snappy-abc-content-2" => "" }
    engine = FakeContainerEngine.new(
      capture_result: ->(args) { args.first == "ps" ? "dev-snappy-abc-content-1\trunning\ndev-snappy-abc-content-2\texited\n\n" : volumes.fetch(args.last) },
    )
    bc = build_container(engine: engine)

    Expect "records in docker's order, from the label filter (a name regex would also match other checkouts' prefixes), each with the prefix volume it mounts"
    bc.service_containers(root).map { |c| [c.name, c.running, c.prefix_volume] } == [
      ["dev-snappy-abc-content-1", true, "dev-linuxbrew-jp"],
      ["dev-snappy-abc-content-2", false, nil],
    ]
    engine.captures.first == [
      "ps", "-a",
      "--filter", "label=#{Dev::BuildContainer::WORKSPACE_LABEL}=#{Dev::BuildContainer.workspace_id(root)}",
      "--format", "{{.Names}}\t{{.State}}",
    ]
  end

  test "container_running? reflects the inspected running state" do
    Given "docker inspect reporting the state"
    engine = FakeContainerEngine.new(capture_result: "true\n")

    Expect "the container counts as running"
    build_container(engine: engine).container_running?("dev-x") == true
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/container_engine"
require "dev/settings"
require "tmpdir"
require "fileutils"

transform!(RSpock::AST::Transformation)
class Dev::ContainerEngineTest < Minitest::Test
  # Hermetic settings: both layer files live under a temp dir, so the
  # machine's real config never leaks into resolution tests.
  def build_settings(dir, user_yaml: nil)
    if user_yaml
      path = File.join(dir, "user", "config.yml")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, user_yaml)
    end
    Dev::Settings.new(
      config_path: File.join(dir, "user", "config.yml"),
      system_config_path: File.join(dir, "system", "config.yml"),
    )
  end

  test "no record on #{host_os} resolves #{kind}: the host OS picks the engine" do
    Given "empty settings, no DOCKER_HOST, a #{host_os} host"
    dir = Dir.mktmpdir("dev-engine-test-")
    engine = Dev::ContainerEngine.resolve(settings: build_settings(dir), env: {}, host_os: host_os)

    Expect "bare docker argv; only colima adds env (its socket)"
    engine.kind == kind
    engine.argv_prefix == ["docker"]
    engine.env.key?("DOCKER_HOST") == (kind == :colima)
    engine.local_mounts?

    Cleanup
    FileUtils.rm_rf(dir)

    Where
    host_os   | kind
    "darwin"  | :colima
    "linux"   | :docker
    "windows" | :docker
  end

  test "an explicit DOCKER_HOST wins over any per-user record" do
    Given "a colima record AND an explicit DOCKER_HOST in the environment"
    dir = Dir.mktmpdir("dev-engine-test-")
    settings = build_settings(dir, user_yaml: "container_engine: colima\n")
    engine = Dev::ContainerEngine.resolve(
      settings: settings, env: { "DOCKER_HOST" => "ssh://build-box" },
    )

    Expect "the explicit engine: bare docker inheriting the caller's DOCKER_HOST"
    engine.kind == :explicit
    engine.argv_prefix == ["docker"]
    engine.env == {}
    engine.local_mounts?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "an empty DOCKER_HOST counts as unset" do
    Given "an empty-string DOCKER_HOST and a colima record"
    dir = Dir.mktmpdir("dev-engine-test-")
    settings = build_settings(dir, user_yaml: "container_engine: colima\n")
    engine = Dev::ContainerEngine.resolve(settings: settings, env: { "DOCKER_HOST" => "" })

    Expect "resolution falls through to the record"
    engine.kind == :colima

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a colima record resolves the user's own socket (per-user substrate)" do
    Given "a per-user engine record naming colima"
    dir = Dir.mktmpdir("dev-engine-test-")
    settings = build_settings(dir, user_yaml: "container_engine: colima\n")
    engine = Dev::ContainerEngine.resolve(settings: settings, env: {})

    Expect "bare docker pointed at the invoking user's colima socket"
    engine.kind == :colima
    engine.argv_prefix == ["docker"]
    engine.env == { "DOCKER_HOST" => "unix://#{Dir.home}/.colima/default/docker.sock" }
    engine.local_mounts?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a docker record resolves bare dockerd on any host, overriding the macOS colima default" do
    Given "a per-user engine record naming docker, on a darwin host"
    dir = Dir.mktmpdir("dev-engine-test-")
    settings = build_settings(dir, user_yaml: "container_engine: docker\n")
    engine = Dev::ContainerEngine.resolve(settings: settings, env: {}, host_os: "darwin")

    Expect "bare docker with no env — whatever daemon the CLI's own context reaches"
    engine.kind == :docker
    engine.env == {}

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a colima record on a non-macOS host still resolves colima (the record is the user's call)" do
    Given "a colima record on linux"
    dir = Dir.mktmpdir("dev-engine-test-")
    settings = build_settings(dir, user_yaml: "container_engine: colima\n")
    engine = Dev::ContainerEngine.resolve(settings: settings, env: {}, host_os: "linux")

    Expect
    engine.kind == :colima

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "an unknown engine record raises instead of silently defaulting" do
    Given "a record naming an engine dev does not ship"
    dir = Dir.mktmpdir("dev-engine-test-")
    settings = build_settings(dir, user_yaml: "container_engine: podman\n")

    When "resolving"
    Dev::ContainerEngine.resolve(settings: settings, env: {})

    Then
    raises Dev::ContainerEngine::UnknownEngineError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "run executes through the engine's argv prefix and reports success as a boolean" do
    Given "engines whose prefix is a command with a known exit code"
    truthy = Dev::ContainerEngine.new(kind: :test, argv_prefix: ["true"])
    falsy = Dev::ContainerEngine.new(kind: :test, argv_prefix: ["false"])

    Expect "the child's status as true/false, never nil"
    truthy.run([]) == true
    falsy.run([]) == false
  end

  test "run and capture carry the engine's env to the child" do
    Given "an engine whose env declares a marker variable"
    engine = Dev::ContainerEngine.new(
      kind: :test, argv_prefix: ["sh", "-c"], env: { "DEV_ENGINE_MARKER" => "on" },
    )

    Expect "the child sees the engine env, and per-call env merges over it"
    engine.capture(['echo "$DEV_ENGINE_MARKER"']) == "on\n"
    engine.run(['test "$DEV_ENGINE_MARKER" = on'])
    engine.capture(['echo "$DEV_ENGINE_MARKER"'], env: { "DEV_ENGINE_MARKER" => "override" }) == "override\n"
  end

  test "capture returns stdout and discards stderr" do
    Given "an engine that writes to both streams"
    engine = Dev::ContainerEngine.new(kind: :test, argv_prefix: ["sh", "-c"])

    Expect
    engine.capture(["echo out; echo noise >&2"]) == "out\n"
  end

  test "capture collapses failures to empty output (probes are best-effort)" do
    Given "engines whose invocations fail or cannot start at all"
    failing = Dev::ContainerEngine.new(kind: :test, argv_prefix: ["sh", "-c"])
    missing = Dev::ContainerEngine.new(kind: :test, argv_prefix: ["dev-test-missing-binary-xyz"])

    Expect "a nonzero exit and a missing binary both read as no output"
    failing.capture(["echo partial; exit 1"]) == ""
    missing.capture(["anything"]) == ""
  end

  test "resources reads the daemon's cpu and memory through docker info" do
    Given "an engine whose docker answers info with NCPU and MemTotal"
    engine = Dev::ContainerEngine.new(kind: :test, argv_prefix: ["sh", "-c", "echo '12 25145466880' #"])

    When "inspecting"
    resources = engine.resources

    Then "the value object carries whole cpus and GiB"
    resources == Dev::EngineResources.new(cpus: 12, memory_gib: 24)
  end

  test "resources is nil when the daemon does not answer usefully (no engine to size against)" do
    Given "an engine whose docker #{shape}"
    engine = Dev::ContainerEngine.new(kind: :test, argv_prefix: argv_prefix)

    Expect
    engine.resources.nil?

    Where
    shape                         | argv_prefix
    "fails outright"              | ["false"]
    "answers something unparsable" | ["sh", "-c", "echo 'Cannot connect to the Docker daemon' #"]
  end

  test "running_containers reads one record per running container, with the dev label contract decoded" do
    Given "an engine whose docker ps lists a dev-managed container and a foreign one"
    listing = "dev-snappy-linux-9f86d08ab1-content-4c2e\ttrue\t/Users/jp/src/snappy\nmy-postgres\t\t\n"
    engine = Dev::ContainerEngine.new(kind: :test, argv_prefix: ["sh", "-c", "printf '#{listing}' #"])

    When "listing"
    records = engine.running_containers

    Then "managed containers carry their checkout; foreign ones are bare names"
    records.size == 2
    records.fetch(0).name == "dev-snappy-linux-9f86d08ab1-content-4c2e"
    records.fetch(0).managed == true
    records.fetch(0).project_root == "/Users/jp/src/snappy"
    records.fetch(1).name == "my-postgres"
    records.fetch(1).managed == false
    records.fetch(1).project_root.nil?
  end

  test "running_containers is empty when nothing runs or the daemon does not answer" do
    Given "an engine whose docker #{shape}"
    engine = Dev::ContainerEngine.new(kind: :test, argv_prefix: argv_prefix)

    Expect
    engine.running_containers.empty?

    Where
    shape                  | argv_prefix
    "lists no containers"  | ["sh", "-c", "true #"]
    "is down"              | ["false"]
  end

  test "idle_stoppable? is true for the engines dev provisions and false for the user's own DOCKER_HOST" do
    Given "an engine of kind #{kind}"
    engine = Dev::ContainerEngine.new(kind: kind)

    Expect
    engine.idle_stoppable? == stoppable

    Where
    kind      | stoppable
    :colima   | true
    :docker   | true
    :explicit | false
  end

  test "run reports a missing binary as failure, not an exception" do
    Given "an engine whose prefix does not exist"
    engine = Dev::ContainerEngine.new(kind: :test, argv_prefix: ["dev-test-missing-binary-xyz"])

    Expect
    engine.run(["anything"]) == false
  end

  test "DEV_CONTAINER_ENGINE env layer overrides the user file, like every settings key" do
    Given "a docker record in the file and a colima override in dev's env layer"
    dir = Dir.mktmpdir("dev-engine-test-")
    settings = build_settings(dir, user_yaml: "container_engine: docker\n")
    ENV["DEV_CONTAINER_ENGINE"] = "colima"

    When "resolving with no DOCKER_HOST"
    engine = Dev::ContainerEngine.resolve(settings: settings, env: {})

    Then "the settings env layer wins within the record"
    engine.kind == :colima

    Cleanup
    ENV.delete("DEV_CONTAINER_ENGINE")
    FileUtils.rm_rf(dir)
  end
end

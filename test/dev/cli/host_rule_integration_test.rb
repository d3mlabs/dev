# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev"
require "dev/build_container"
require "dev/container_github_token"
require "dev/deps"
require "dev/deps/dependency"
require "dev/deps/lockfile"
require "dev/environment_image"
require "dev/host_environment"
require "dev/cli/host_rule"
require "dev/project_container"
require "dev/cli/runner"
require "support/fake_container_engine"
require "support/scripted_remote"
require "fileutils"
require "pathname"
require "stringio"
require "tmpdir"
require "yaml"

# dev#308's done-when, through the composition root: a Linux host and a
# checkout pinning one image. What decides where a command runs is the
# host's /etc/dev/environment marker against the lock — not the platform.
# The process boundaries are faked (engine, exec, the marker's path, the
# runner's snapshot push); everything between dev.yml and the argv dev
# would exec — or hand the engine — is real.
transform!(RSpock::AST::Transformation)
class HostRuleIntegrationTest < Minitest::Test
  include SorbetHelper

  COMMANDS = { "build" => { "run" => "./bin/build.sh" }, "editor" => { "run" => "./bin/editor.sh", "environment" => "host" } }.freeze

  def setup
    @original_cwd = Dir.pwd
    @root = Pathname(Dir.mktmpdir("host-rule-fixture"))
    @marker = @root / "etc-dev-environment"
    @data_root = Dir.mktmpdir("host-rule-data-root")
    @original_data_root = ENV.fetch("DEV_DATA_ROOT", nil)
    ENV["DEV_DATA_ROOT"] = @data_root
    # A workstation: the fixture is never `dev up`'d, and in CI the
    # staleness guard would refuse the command.
    @original_ci = ENV.fetch("CI", nil)
    ENV.delete("CI")
    # The composition root builds `up` on its platform default
    # (`LinuxDataRootProvisioner.for_host`), which on the Linux host below
    # reads the process env — DEV_DATA_ROOT, set above — so it answers
    # nil on every machine.
    @host_probes = allow_host_probes
    @engine = FakeContainerEngine.new(&method(:docker_succeeds?))
    @stderr = StringIO.new
    @original_stderr = $stderr
    $stderr = @stderr
  end

  def teardown
    restore_host_probe_guard(@host_probes)
    $stderr = @original_stderr
    @original_data_root.nil? ? ENV.delete("DEV_DATA_ROOT") : ENV["DEV_DATA_ROOT"] = @original_data_root
    ENV["CI"] = @original_ci if @original_ci
    Dir.chdir(@original_cwd)
    FileUtils.rm_rf([@root, @data_root])
    super
  end

  test "a Linux host provisioned from the lock's image runs the image's command here, no container" do
    Given "the marker is the lock's pin"
    image = lock
    @marker.write(image.marker)

    When
    exec!(runner, ["build"])

    Then
    1 * Kernel.exec(anything, "shadowenv", "exec", "--dir", @root.to_s, "--", "sh", "-c", includes("./bin/build.sh"))
    @engine.runs.empty?
  end

  test "a Linux host on the image's platform but provisioned from nothing runs the command inside — the host's data root and the checkout bind-mounted at their own paths" do
    Given "no marker"
    image = lock
    checkout = Dev::BuildContainer.workspace_path(@root)

    When
    status = exec!(runner, ["build"])

    Then "one docker run of the lock's image through the engine, the process exiting with its status; the data root and the checkout are the bind mounts; the checkout the workdir; DEV_DATA_ROOT named on argv, valued in the spawn env; the command last"
    0 * Kernel.exec
    status == 0
    run = @engine.runs.find { |verb, *_rest| verb == "run" }
    run.first(2) == ["run", "--rm"]
    run.include?(image.ref)
    run.last(3) == ["sh", "-c", "./bin/build.sh"]
    bind_mounts(run) == ["#{@data_root}:#{@data_root}", "#{checkout}:#{checkout}"]
    run.each_cons(2).include?(["-w", checkout])
    run.each_cons(2).include?(["-e", "DEV_DATA_ROOT"])
    @engine.run_envs.fetch(@engine.runs.index(run))["DEV_DATA_ROOT"] == @data_root
  end

  test "a Linux host provisioned from an older recipe has drifted: the command runs inside the lock's image" do
    Given
    image = lock
    @marker.write(older_recipe_of(image).marker)

    When
    status = exec!(runner, ["build"])

    Then
    0 * Kernel.exec
    status == 0
    run = @engine.runs.find { |verb, *_rest| verb == "run" }
    run.first(2) == ["run", "--rm"]
    run.include?(image.ref)
  end

  test "inside a container made from an older recipe, the command is refused with the way out" do
    Given
    image = lock
    @marker.write(older_recipe_of(image).marker)

    When
    runner(inside_container: true).run(["build"])

    Then
    0 * Kernel.exec
    exit = raises SystemExit
    exit.status == 1
    @stderr.string.include?("dev: this container is snappy-linux@#{older_recipe_of(image).short_digest}")
    @stderr.string.include?("re-create it from the host: `dev container reset && dev up`")
  end

  test "environment: host is the host whatever the marker says" do
    Given
    lock

    When
    exec!(runner, ["editor"])

    Then
    1 * Kernel.exec(anything, "shadowenv", "exec", "--dir", @root.to_s, "--", "sh", "-c", includes("./bin/editor.sh"))
  end

  private

  def docker_succeeds?(args)
    args.first(2) != ["container", "inspect"]
  end

  # The host paths docker was handed with -v, bind mounts only (a named
  # volume has no slash).
  def bind_mounts(argv)
    argv.each_cons(2).select { |flag, _| flag == "-v" }.map(&:last).select { |spec| spec.start_with?("/") }
  end

  # Run a command to its end and answer its exit status. A container-placed
  # run exits with the container's status; a host run's exec is faked and
  # "returns", which the executor's never-returns contract reports — both
  # expected here, and the host run has no status to answer.
  def exec!(runner, argv)
    runner.run(argv)
    nil
  rescue Dev::Cli::ProjectExecutor::ExecReturnedError
    nil
  rescue SystemExit => e
    e.status
  end

  # A Runner over a dev.yml written into the fixture root, composed for a
  # Linux host whose marker is the fixture's.
  def runner(inside_container: false)
    (@root / "dev.yml").write(YAML.dump({ "name" => "snappy", "commands" => COMMANDS }))
    host_rule = Dev::Cli::HostRule.new(
      host_environment: Dev::HostEnvironment.new(path: @marker.to_s), inside_container:,
    )
    Dev::Cli::Runner.new(
      dev_yaml_path: @root / "dev.yml", ui: Dev::NoUi.new(out: StringIO.new), out: StringIO.new, host_rule: host_rule, host_os: "linux",
      hosts_factory: method(:remote_hosts).to_proc,
    )
  end

  # The project's container over the fake engine (a host whose gh holds no
  # login) and, for the runner transport, a sync step that pushes nothing.
  def remote_hosts(project)
    Dev::Cli::Runner::RemoteHosts.new(
      containers: Dev::ProjectContainer.new(
        project_root: project.root, engine_hint: project.engine, client: Dev::BuildContainer.new(engine: @engine, host_os: "linux"),
        github_token: Dev::ContainerGithubToken.new(source: -> { nil }),
      ),
      sync_for: ->(_root) { ScriptedRemote::CannedSync.new },
    )
  end

  # Lock one image and return it.
  def lock
    pin = Dev::Deps::Dependency.new(
      name: "snappy-linux", integration: :image, group: :app, version: "ue5.8-3", hash: "SHA256=#{"a" * 64}",
      metadata: {
        "from" => "ghcr.io/d3mlabs/unreal-engine-build-base", "platform" => "linux/amd64",
        "platforms" => ["linux/amd64"], "registry" => "ghcr.io/d3mlabs", "apt" => ["winbind"],
      },
    )
    Dev::Deps::Lockfile.new(dir: @root).lock(Dev::EnvironmentImage.stamp([pin]))
    Dev::EnvironmentImage.from_pin(Dev::Deps::Lockfile.new(dir: @root).read.first)
  end

  def older_recipe_of(image)
    Dev::EnvironmentImage.new(
      name: image.name, from: image.from, from_digest: image.from_digest, platform: image.platform,
      apt: [], registry: image.registry,
    )
  end
end

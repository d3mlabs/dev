# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev"
require "dev/build_container"
require "dev/container_engine"
require "dev/container_github_token"
require "dev/deps"
require "dev/deps/dependency"
require "dev/deps/lockfile"
require "dev/environment_image"
require "dev/host_environment"
require "dev/host_rule"
require "dev/platform"
require "dev/project_container"
require "dev/runner"
require "dev/shadowenv_llvm"
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
# snapshot push and the repo gh would name); everything between dev.yml
# and the argv dev would exec — or hand the engine — is real.
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
    Dev.stubs(:target_project_root).returns(@root)
    Dev::Deps.stubs(:detect_env).returns("dev")
    Dev::Platform.stubs(:current).returns("linux-x86_64")
    Dev::Platform.stubs(:os).returns("linux")
    @engine = FakeContainerEngine.new(&method(:docker_succeeds?))
    Dev::ContainerEngine.stubs(:resolve).returns(@engine)
    Dev::ShadowenvLlvm.stubs(:project_needs_llvm?).returns(false)
    @stderr = StringIO.new
    @original_stderr = $stderr
    $stderr = @stderr
  end

  def teardown
    $stderr = @original_stderr
    @original_data_root.nil? ? ENV.delete("DEV_DATA_ROOT") : ENV["DEV_DATA_ROOT"] = @original_data_root
    Dir.chdir(@original_cwd)
    FileUtils.rm_rf([@root, @data_root])
    super
  end

  test "a Linux host provisioned from the lock's image runs the image's command here, no container" do
    Given "the marker is the lock's pin"
    image = lock
    @marker.write(image.marker)
    execs = record_execs

    When
    exec!(runner, ["build"])

    Then
    execs.size == 1
    execs[0].first(5) == ["shadowenv", "exec", "--", "sh", "-c"]
    execs[0].last.include?("./bin/build.sh")
    @engine.runs.empty?
  end

  test "a Linux host on the image's platform but provisioned from nothing runs the command inside — the host's data root bind-mounted, the checkout not: the container fetches the snapshot" do
    Given "no marker"
    image = lock
    execs = record_execs
    Kernel.expects(:exit).with(0).once

    When
    exec!(runner, ["build"])

    Then "one docker run of the lock's image through the engine; the host's data root at its own path is the one bind mount; DEV_DATA_ROOT named on argv, valued in the spawn env; the command at the end of the workspace program"
    execs.empty?
    run = @engine.runs.find { |verb, *_rest| verb == "run" }
    run.first(2) == ["run", "--rm"]
    run.include?(image.ref)
    run[-3, 2] == ["sh", "-c"]
    run.last.include?("fetch -q --no-tags https://github.com/o/r.git refs/heads/dev/build/container/")
    run.last.end_with?("exec sh -c ./bin/build.sh\n")
    bind_mounts(run) == ["#{@data_root}:#{@data_root}"]
    run.each_cons(2).include?(["-e", "DEV_DATA_ROOT"])
    @engine.run_envs.fetch(@engine.runs.index(run))["DEV_DATA_ROOT"] == @data_root
  end

  test "a Linux host provisioned from an older recipe has drifted: the command runs inside the lock's image" do
    Given
    image = lock
    @marker.write(older_recipe_of(image).marker)
    execs = record_execs
    Kernel.stubs(:exit)

    When
    exec!(runner, ["build"])

    Then
    execs.empty?
    run = @engine.runs.find { |verb, *_rest| verb == "run" }
    run.first(2) == ["run", "--rm"]
    run.include?(image.ref)
  end

  test "inside a container made from an older recipe, the command is refused with the way out" do
    Given
    image = lock
    @marker.write(older_recipe_of(image).marker)
    Dev::ContainerContext.stubs(:inside?).returns(true)
    Kernel.expects(:exec).never
    Kernel.expects(:exit).with(1).once

    When
    runner.run(["build"])

    Then
    @stderr.string.include?("dev: this container is snappy-linux@#{older_recipe_of(image).short_digest}")
    @stderr.string.include?("re-create it from the host: `dev container reset && dev up`")
  end

  test "environment: host is the host whatever the marker says" do
    Given
    lock
    execs = record_execs

    When
    exec!(runner, ["editor"])

    Then
    execs.size == 1
    execs[0].first(5) == ["shadowenv", "exec", "--", "sh", "-c"]
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

  def exec!(runner, argv)
    runner.run(argv)
  rescue Dev::ProjectExecutor::ExecReturnedError
    nil
  end

  def record_execs
    execs = []
    Kernel.stubs(:exec).with { |_env, *argv| execs << argv }
    execs
  end

  def runner
    (@root / "dev.yml").write(YAML.dump({ "name" => "snappy", "commands" => COMMANDS }))
    ui = typed_mock(Dev::Cli::Ui)
    ui.stubs(:print_header)
    ui.stubs(:print_remote_crossing)
    host_rule = Dev::HostRule.new(
      host_environment: Dev::HostEnvironment.new(path: @marker.to_s),
    )
    Dev::Runner.new(dev_yaml_path: @root / "dev.yml", ui: ui, out: StringIO.new, host_rule: host_rule, hosts_factory: method(:remote_hosts).to_proc)
  end

  # The project's container over the fake engine (a host whose gh holds no
  # login, the repo named without gh) and a sync step that pushes nothing.
  def remote_hosts(project)
    Dev::Runner::RemoteHosts.new(
      containers: Dev::ProjectContainer.new(
        project_root: project.root, engine_hint: project.engine, client: Dev::BuildContainer.new(engine: @engine),
        github_token: Dev::ContainerGithubToken.new(source: -> { nil }), repo_resolver: -> { "o/r" },
      ),
      sync: ScriptedRemote::CannedSync.new,
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

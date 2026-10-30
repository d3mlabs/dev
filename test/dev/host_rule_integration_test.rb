# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/container_github_token"
require "dev"
require "dev/container_engine"
require "dev/deps"
require "dev/deps/dependency"
require "dev/deps/lockfile"
require "dev/environment_image"
require "dev/host_environment"
require "dev/host_rule"
require "dev/platform"
require "dev/runner"
require "dev/shadowenv_llvm"
require "support/fake_container_engine"
require "fileutils"
require "pathname"
require "stringio"
require "tmpdir"
require "yaml"

# dev#308's done-when, through the composition root: a Linux host and a
# checkout pinning one image. What decides where a command runs is the
# host's /etc/dev/environment marker against the lock — not the platform.
# The process boundaries are faked (engine, exec, the marker's path);
# everything between dev.yml and the argv dev would exec is real.
transform!(RSpock::AST::Transformation)
class HostRuleIntegrationTest < Minitest::Test
  include SorbetHelper

  COMMANDS = { "build" => { "run" => "./bin/build.sh" }, "editor" => { "run" => "./bin/editor.sh", "runs_on" => "host" } }.freeze

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

  test "a Linux host on the image's platform but provisioned from nothing runs the command inside — with its own data root bind-mounted" do
    Given "no marker"
    image = lock
    execs = []
    envs = []
    Kernel.stubs(:exec).with do |env, *argv|
      execs << argv
      envs << env
    end

    When
    exec!(runner, ["build"])

    Then "docker run of the lock's image; the host's data root at its own path, the checkout: the two bind mounts; DEV_DATA_ROOT named on argv, valued in the spawn env"
    execs.size == 1
    execs[0].first(3) == ["docker", "run", "--rm"]
    execs[0].last(6) == ["-w", "/project", image.ref, "sh", "-c", "./bin/build.sh"]
    bind_mounts(execs[0]) == ["#{@root}:/project", "#{@data_root}:#{@data_root}"]
    execs[0].each_cons(2).include?(["-e", "DEV_DATA_ROOT"])
    envs[0]["DEV_DATA_ROOT"] == @data_root
  end

  test "a Linux host provisioned from an older recipe has drifted: the command runs inside the lock's image" do
    Given
    image = lock
    @marker.write(older_recipe_of(image).marker)
    execs = record_execs

    When
    exec!(runner, ["build"])

    Then
    execs.size == 1
    execs[0].first(3) == ["docker", "run", "--rm"]
    execs[0].include?(image.ref)
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

  test "runs_on: host is the host whatever the marker says" do
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
    host_rule = Dev::HostRule.new(
      host_environment: Dev::HostEnvironment.new(path: @marker.to_s),
    )
    Dev::Runner.new(dev_yaml_path: @root / "dev.yml", ui: ui, out: StringIO.new, host_rule: host_rule,
      github_token: Dev::ContainerGithubToken.new(source: -> { nil }))
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

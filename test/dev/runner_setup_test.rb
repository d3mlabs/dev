# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/runner_setup_config"
require "dev/runner_setup"
require "tmpdir"
require "fileutils"
require "stringio"
require "socket"

transform!(RSpock::AST::Transformation)
class Dev::RunnerSetupTest < Minitest::Test
  # Records system invocations and answers capture calls from a responder, so the
  # orchestration runs end to end without touching gh/curl/svc.sh.
  class RecordingExecutor
    attr_reader :systems

    def initialize(&capture_responder)
      @capture_responder = capture_responder
      @systems = []
    end

    def capture(*argv)
      @capture_responder ? @capture_responder.call(argv) : ["", "", true]
    end

    def system(*argv, chdir: nil)
      @systems << { argv: argv, chdir: chdir }
      true
    end
  end

  def silent = StringIO.new

  def authed_responder
    lambda do |argv|
      next ["owner/repo\n", "", true] if argv[0, 3] == ["gh", "repo", "view"]
      next ["TOKEN123\n", "", true] if argv.any? { |arg| arg.include?("registration-token") }

      ["", "", true]
    end
  end

  test "config_argv builds the config.sh registration contract" do
    Given "a runner config with labels"
    config = Dev::RunnerSetupConfig.new(labels: "ue-engine,x64")
    setup = Dev::RunnerSetup.new(config: config)

    When "building the config argv"
    argv = setup.config_argv(url: "https://github.com/owner/repo", token: "T", name: "box")

    Then
    argv == [
      "./config.sh",
      "--url", "https://github.com/owner/repo",
      "--token", "T",
      "--labels", "ue-engine,x64",
      "--name", "box",
      "--unattended",
      "--replace",
    ]
  end

  test "resolve_dir defaults to a label-suffixed path under HOME" do
    Given "a config without an explicit dir"
    config = Dev::RunnerSetupConfig.new(labels: "ue-engine,x64")
    setup = Dev::RunnerSetup.new(config: config)

    Expect "the dir derives from the first label"
    setup.resolve_dir == File.expand_path("~/actions-runner-ue-engine")
  end

  test "resolve_dir expands an explicit dir" do
    Given "a config with an explicit dir"
    config = Dev::RunnerSetupConfig.new(labels: "snappy", dir: "~/actions-runner")
    setup = Dev::RunnerSetup.new(config: config)

    Expect
    setup.resolve_dir == File.expand_path("~/actions-runner")
  end

  test "resolve_name and resolve_version fall back to host defaults" do
    Given "a config without name or version"
    config = Dev::RunnerSetupConfig.new(labels: "snappy")
    setup = Dev::RunnerSetup.new(config: config)

    Expect
    setup.resolve_name == Socket.gethostname
    setup.resolve_version == Dev::RunnerSetup::DEFAULT_VERSION
  end

  test "run rejects a Windows-mounted dir before touching the network" do
    Given "a config pointing at a /mnt path"
    config = Dev::RunnerSetupConfig.new(labels: "snappy", dir: "/mnt/c/actions-runner")
    exec = RecordingExecutor.new
    setup = Dev::RunnerSetup.new(config: config, executor: exec, out: silent)

    When "running setup"
    setup.run

    Then "it raises before running any command"
    raises Dev::RunnerSetup::Error
  end

  test "run fails fast when gh is not authenticated" do
    Given "an executor where gh auth status fails"
    config = Dev::RunnerSetupConfig.new(labels: "snappy", dir: Dir.mktmpdir)
    exec = RecordingExecutor.new { |argv| argv[0, 3] == ["gh", "auth", "status"] ? ["", "no", false] : ["", "", true] }
    setup = Dev::RunnerSetup.new(config: config, executor: exec, out: silent)

    When "running setup"
    setup.run

    Then
    raises Dev::RunnerSetup::Error

    Cleanup
    FileUtils.remove_entry(config.dir)
  end

  test "run registers and installs the service, skipping download when present" do
    Given "a runner dir that already has an executable config.sh"
    dir = Dir.mktmpdir
    config_sh = File.join(dir, "config.sh")
    File.write(config_sh, "#!/bin/bash\n")
    File.chmod(0o755, config_sh)
    config = Dev::RunnerSetupConfig.new(labels: "ue-engine", dir: dir, name: "box")
    exec = RecordingExecutor.new(&authed_responder)
    setup = Dev::RunnerSetup.new(config: config, executor: exec, out: silent)

    When "running setup with a repo override"
    setup = Dev::RunnerSetup.new(config: config, repo: "owner/repo", executor: exec, out: silent)
    setup.run

    Then "config.sh registers with the minted token, the service starts, no download happens"
    register = exec.systems.find { |call| call[:argv].first == "./config.sh" }
    register[:chdir] == dir
    register[:argv] == [
      "./config.sh",
      "--url", "https://github.com/owner/repo",
      "--token", "TOKEN123",
      "--labels", "ue-engine",
      "--name", "box",
      "--unattended",
      "--replace",
    ]
    exec.systems.any? { |call| call[:argv] == ["sudo", "./svc.sh", "install"] && call[:chdir] == dir }
    exec.systems.any? { |call| call[:argv] == ["sudo", "./svc.sh", "start"] && call[:chdir] == dir }
    exec.systems.none? { |call| call[:argv].first == "curl" }

    Cleanup
    FileUtils.remove_entry(dir)
  end

  test "run downloads the runner when config.sh is absent" do
    Given "an empty runner dir"
    dir = Dir.mktmpdir
    config = Dev::RunnerSetupConfig.new(labels: "ue-engine", dir: dir, version: "9.9.9")
    exec = RecordingExecutor.new(&authed_responder)
    setup = Dev::RunnerSetup.new(config: config, repo: "owner/repo", executor: exec, out: silent)

    When "running setup"
    setup.run

    Then "the pinned runner version is fetched and extracted"
    curl = exec.systems.find { |call| call[:argv].first == "curl" }
    curl[:chdir] == dir
    curl[:argv].last == "https://github.com/actions/runner/releases/download/v9.9.9/actions-runner-linux-x64-9.9.9.tar.gz"
    exec.systems.any? { |call| call[:argv].first == "tar" }

    Cleanup
    FileUtils.remove_entry(dir)
  end
end

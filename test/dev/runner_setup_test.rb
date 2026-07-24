# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/runner_setup_config"
require "dev/runner_setup"
require "tmpdir"
require "fileutils"
require "json"
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
      next ["RMTOKEN\n", "", true] if argv.any? { |arg| arg.include?("remove-token") }
      next ["TOKEN123\n", "", true] if argv.any? { |arg| arg.include?("registration-token") }

      ["", "", true]
    end
  end

  # An authed executor that also appends each capture call (as a joined command
  # line) to `captured`. A lambda (like authed_responder) because plain blocks
  # auto-splat their single array argument under RSpock's transformation.
  def capturing_executor(captured)
    responder = authed_responder
    recorder = lambda do |argv|
      captured << argv.join(" ")
      responder.call(argv)
    end
    RecordingExecutor.new(&recorder)
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
    setup = Dev::RunnerSetup.new(config: config, repo: "owner/repo", executor: exec, out: silent,
      host_platform: "linux-x64")
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
    exec.systems.none? { |call| call[:argv] == ["sudo", "./svc.sh", "status"] }
    exec.systems.none? { |call| call[:argv].first == "curl" }
    exec.systems.none? { |call| call[:argv][0, 2] == ["./config.sh", "remove"] }

    Cleanup
    FileUtils.remove_entry(dir)
  end

  test "run with org scope registers against the org URL with an org-minted token" do
    Given "a runner dir that already has an executable config.sh"
    dir = Dir.mktmpdir
    config_sh = File.join(dir, "config.sh")
    File.write(config_sh, "#!/bin/bash\n")
    File.chmod(0o755, config_sh)
    config = Dev::RunnerSetupConfig.new(labels: "ai-light,ai-build", dir: dir, name: "box")
    captured = []
    exec = capturing_executor(captured)

    When "running setup org-wide"
    setup = Dev::RunnerSetup.new(config: config, repo: "owner/repo", org: true, executor: exec,
      out: silent, host_platform: "osx-arm64")
    setup.run

    Then "the registration token is minted at the org endpoint and config.sh targets the org URL"
    captured.any? { |line| line.include?("orgs/owner/actions/runners/registration-token") }
    captured.none? { |line| line.include?("repos/owner/repo/actions/runners/registration-token") }
    register = exec.systems.find { |call| call[:argv].first == "./config.sh" }
    register[:argv][1, 2] == ["--url", "https://github.com/owner"]

    Cleanup
    FileUtils.remove_entry(dir)
  end

  test "run migrates a repo-scoped runner to org scope by removing at the old scope first" do
    Given "a runner dir configured at the repo scope (per its .runner gitHubUrl)"
    dir = Dir.mktmpdir
    config_sh = File.join(dir, "config.sh")
    File.write(config_sh, "#!/bin/bash\n")
    File.chmod(0o755, config_sh)
    # config.sh writes .runner with a UTF-8 BOM; reproduce it so the scope
    # parse is exercised against the real file shape.
    File.write(File.join(dir, ".runner"), "\uFEFF#{JSON.generate("gitHubUrl" => "https://github.com/owner/repo")}")
    File.write(File.join(dir, ".service"), "actions.runner.plist\n")
    config = Dev::RunnerSetupConfig.new(labels: "ai-light", dir: dir, name: "box")
    captured = []
    exec = capturing_executor(captured)

    When "re-running setup org-wide"
    setup = Dev::RunnerSetup.new(config: config, repo: "owner/repo", org: true, executor: exec,
      out: silent, host_platform: "osx-arm64")
    setup.run

    Then "the installed service is uninstalled, the remove token comes from the old repo scope, " \
         "and the new registration from the org scope"
    uninstall_idx = exec.systems.index { |call| call[:argv] == ["./svc.sh", "uninstall"] }
    remove_idx = exec.systems.index { |call| call[:argv][0, 2] == ["./config.sh", "remove"] }
    register_idx = exec.systems.index { |call| call[:argv][0, 2] == ["./config.sh", "--url"] }
    uninstall_idx < remove_idx
    remove_idx < register_idx
    captured.any? { |line| line.include?("repos/owner/repo/actions/runners/remove-token") }
    captured.any? { |line| line.include?("orgs/owner/actions/runners/registration-token") }

    Cleanup
    FileUtils.remove_entry(dir)
  end

  test "run removes an existing runner config before reconfiguring" do
    Given "a runner dir that is already configured (has .runner)"
    dir = Dir.mktmpdir
    config_sh = File.join(dir, "config.sh")
    File.write(config_sh, "#!/bin/bash\n")
    File.chmod(0o755, config_sh)
    File.write(File.join(dir, ".runner"), "{}")
    config = Dev::RunnerSetupConfig.new(labels: "ue-engine", dir: dir, name: "box")
    exec = RecordingExecutor.new(&authed_responder)
    setup = Dev::RunnerSetup.new(config: config, repo: "owner/repo", executor: exec, out: silent)

    When "running setup"
    setup.run

    Then "config.sh remove runs with the remove token before config.sh registers"
    remove = exec.systems.find { |call| call[:argv][0, 2] == ["./config.sh", "remove"] }
    remove[:argv] == ["./config.sh", "remove", "--token", "RMTOKEN"]
    remove[:chdir] == dir
    remove_idx = exec.systems.index { |call| call[:argv][0, 2] == ["./config.sh", "remove"] }
    register_idx = exec.systems.index { |call| call[:argv][0, 2] == ["./config.sh", "--url"] }
    remove_idx < register_idx

    Cleanup
    FileUtils.remove_entry(dir)
  end

  test "run downloads the runner when config.sh is absent" do
    Given "an empty runner dir"
    dir = Dir.mktmpdir
    config = Dev::RunnerSetupConfig.new(labels: "ue-engine", dir: dir, version: "9.9.9")
    exec = RecordingExecutor.new(&authed_responder)
    setup = Dev::RunnerSetup.new(config: config, repo: "owner/repo", executor: exec, out: silent,
      host_platform: "linux-x64")

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

  test "run on macOS fetches the osx tarball and installs the service without sudo" do
    Given "an empty runner dir on an Apple Silicon host"
    dir = Dir.mktmpdir
    config = Dev::RunnerSetupConfig.new(labels: "macos,ue-editor", dir: dir, version: "9.9.9")
    exec = RecordingExecutor.new(&authed_responder)
    setup = Dev::RunnerSetup.new(config: config, repo: "owner/repo", executor: exec, out: silent,
      host_platform: "osx-arm64")

    When "running setup"
    setup.run

    Then "the osx-arm64 runner is fetched and svc.sh runs as the user (LaunchAgent, not systemd)"
    curl = exec.systems.find { |call| call[:argv].first == "curl" }
    curl[:argv].last == "https://github.com/actions/runner/releases/download/v9.9.9/actions-runner-osx-arm64-9.9.9.tar.gz"
    exec.systems.any? { |call| call[:argv] == ["./svc.sh", "install"] && call[:chdir] == dir }
    exec.systems.any? { |call| call[:argv] == ["./svc.sh", "start"] && call[:chdir] == dir }
    exec.systems.none? { |call| call[:argv].first == "sudo" }

    Cleanup
    FileUtils.remove_entry(dir)
  end

  test "detect_host_platform reflects the current interpreter platform" do
    When "detecting the host platform"
    platform = Dev::RunnerSetup.detect_host_platform

    Then "the slug matches this host's OS"
    if RUBY_PLATFORM.include?("darwin")
      platform.start_with?("osx-")
    else
      platform.start_with?("linux-")
    end
  end
end

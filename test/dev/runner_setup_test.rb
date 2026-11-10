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
require "support/recording_ui"

transform!(RSpock::AST::Transformation)
class Dev::RunnerSetupTest < Minitest::Test
  # Records system invocations (and every call, system or capture, in
  # order) and answers capture calls from a responder, so the orchestration
  # runs end to end without touching gh/curl/svc.sh/config.sh.
  class RecordingExecutor
    attr_reader :systems, :calls

    def initialize(&capture_responder)
      @capture_responder = capture_responder
      @systems = []
      @calls = []
    end

    def capture(*argv, chdir: nil)
      @calls << { argv: argv, chdir: chdir }
      @capture_responder ? @capture_responder.call(argv) : ["", "", true]
    end

    def system(*argv, chdir: nil)
      @systems << { argv: argv, chdir: chdir }
      @calls << { argv: argv, chdir: chdir }
      true
    end
  end

  # A Ui whose plain lines go nowhere: the tests here are about what ran.
  def quiet
    Dev::NoUi.new(out: StringIO.new)
  end

  def authed_responder
    lambda do |argv|
      next ["owner/repo\n", "", true] if argv[0, 3] == ["gh", "repo", "view"]
      next ["RMTOKEN\n", "", true] if argv.any? { |arg| arg.include?("remove-token") }
      next ["TOKEN123\n", "", true] if argv.any? { |arg| arg.include?("registration-token") }

      ["", "", true]
    end
  end

  # An authed executor that also appends each capture call (as a joined command
  # Run the block with these variables set (nil: unset), restoring after.
  def with_env(vars)
    saved = vars.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    vars.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

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

  test "current_repo is the checkout's owner/repo as gh resolves it" do
    Given "a gh that answers for this checkout"
    exec = RecordingExecutor.new(&authed_responder)

    Expect
    Dev::RunnerSetup.current_repo(executor: exec) == "owner/repo"
  end

  test "current_repo raises Error when gh cannot resolve the checkout" do
    Given "a gh outside any repo"
    outside = ->(argv) { argv[0, 3] == ["gh", "repo", "view"] ? ["", "not a git repository", false] : ["", "", true] }
    exec = RecordingExecutor.new(&outside)

    When "asking"
    error = assert_raises(Dev::RunnerSetup::Error) { Dev::RunnerSetup.current_repo(executor: exec) }

    Then "the message carries gh's words"
    error.message.include?("not a git repository")

    Cleanup
    nil
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

  test "config_argv names the runner group when the enrollment joins one (dev#470); unnamed, config.sh lands it in Default" do
    Given "a config for an org host in a named group"
    config = Dev::RunnerSetupConfig.new(labels: "ai-ask,ai-build", group: "agents")
    setup = Dev::RunnerSetup.new(config: config, org: true)

    When "building the config argv"
    argv = setup.config_argv(url: "https://github.com/d3mlabs", token: "T", name: "mac1-2")

    Then "--runnergroup rides between the identity and the modes"
    argv == [
      "./config.sh",
      "--url", "https://github.com/d3mlabs",
      "--token", "T",
      "--labels", "ai-ask,ai-build",
      "--name", "mac1-2",
      "--runnergroup", "agents",
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
    setup = Dev::RunnerSetup.new(config: config, executor: exec, ui: quiet)

    When "running setup"
    setup.run

    Then "it raises before running any command"
    raises Dev::RunnerSetup::Error
  end

  test "run fails fast when gh is not authenticated" do
    Given "an executor where gh auth status fails"
    config = Dev::RunnerSetupConfig.new(labels: "snappy", dir: Dir.mktmpdir)
    exec = RecordingExecutor.new { |argv| argv[0, 3] == ["gh", "auth", "status"] ? ["", "no", false] : ["", "", true] }
    setup = Dev::RunnerSetup.new(config: config, executor: exec, ui: quiet)

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
    setup = Dev::RunnerSetup.new(config: config, executor: exec, ui: quiet)

    When "running setup with a repo override"
    setup = Dev::RunnerSetup.new(config: config, repo: "owner/repo", executor: exec, ui: quiet,
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

  # --- enrolling as the runner user (dev#310) --------------------------

  test "as another user, the dir defaults under that user's home" do
    Given
    config = Dev::RunnerSetupConfig.new(labels: "snappy")
    setup = Dev::RunnerSetup.new(config: config, as_user: "runner", home: "/home/runner")

    Expect
    setup.resolve_dir == "/home/runner/actions-runner-snappy"
  end

  test "as another user, every step that touches the enrollment runs as that user through sudo, and the unit is installed for it" do
    Given "a fresh dir under the runner user's home (nothing there yet) and an admin gh on the operator's side"
    home = Dir.mktmpdir
    dir = File.join(home, "actions-runner-snappy")
    config = Dev::RunnerSetupConfig.new(labels: "snappy", dir: dir, name: "box")
    exec = RecordingExecutor.new(&authed_responder)
    setup = Dev::RunnerSetup.new(config: config, repo: "owner/repo", executor: exec, ui: quiet,
      host_platform: "linux-x64", as_user: "runner", home: home, path: "/opt/brew/bin:/usr/bin")

    When
    setup.run

    Then "the operator's gh mints; mkdir, curl, tar, rm and config.sh run as runner on the host PATH (config.sh records it for every job); svc.sh installs the unit for runner, as root"
    exec.calls.map { |call| call[:argv] }.include?(%w[gh auth status])
    as_runner = ["sudo", "-u", "runner", "-H", "env", "PATH=/opt/brew/bin:/usr/bin"]
    exec.systems.map { |call| call[:argv] } == [
      [*as_runner, "mkdir", "-p", dir],
      [*as_runner, "curl", "-fsSL", "-o", "actions-runner-linux-x64-#{Dev::RunnerSetup::DEFAULT_VERSION}.tar.gz",
       "https://github.com/actions/runner/releases/download/v#{Dev::RunnerSetup::DEFAULT_VERSION}/actions-runner-linux-x64-#{Dev::RunnerSetup::DEFAULT_VERSION}.tar.gz",],
      [*as_runner, "tar", "xzf", "actions-runner-linux-x64-#{Dev::RunnerSetup::DEFAULT_VERSION}.tar.gz"],
      # The tarball's removal is the shared file-op helper (teardown's too): no PATH to carry.
      ["sudo", "-u", "runner", "-H", "rm", "-f", "actions-runner-linux-x64-#{Dev::RunnerSetup::DEFAULT_VERSION}.tar.gz"],
      [*as_runner, "./config.sh",
       "--url", "https://github.com/owner/repo", "--token", "TOKEN123",
       "--labels", "snappy", "--name", "box", "--unattended", "--replace",],
      ["sudo", "./svc.sh", "install", "runner"],
      ["sudo", "./svc.sh", "start"],
    ]
    exec.systems.select { |call| call[:argv].include?("curl") || call[:argv].include?("./config.sh") || call[:argv].include?("./svc.sh") }
      .all? { |call| call[:chdir] == dir }
    !Dir.exist?(dir)

    Cleanup
    FileUtils.remove_entry(home)
  end

  test "run speaks through the Ui: one frame for the enrollment; a step per child handed the terminal (svc.sh, config.sh); a spin per captured gh or config.sh call; a note per thing found — every reason in the text, for the pipe tier (plans#52)" do
    Given "a configured, serviced dir being re-enrolled as the runner user"
    dir = Dir.mktmpdir
    config_sh = File.join(dir, "config.sh")
    File.write(config_sh, "#!/bin/bash\n")
    File.chmod(0o755, config_sh)
    File.write(File.join(dir, ".runner"), "\uFEFF#{JSON.generate("gitHubUrl" => "https://github.com/owner/repo")}")
    File.write(File.join(dir, ".service"), "unit")
    config = Dev::RunnerSetupConfig.new(labels: "snappy", dir: dir, name: "box")
    ui = RecordingUi.new
    setup = Dev::RunnerSetup.new(config: config, repo: "owner/repo", executor: RecordingExecutor.new(&authed_responder),
      ui: ui, host_platform: "linux-x64", as_user: "runner", home: File.dirname(dir))

    When
    setup.run

    Then
    ui.rows == [
      [:frame, "Runner 'box' for owner/repo as runner (labels: snappy)", 0],
      [:note, "actions-runner already present in #{dir}", 1],
      [:note, "Existing runner config found (owner/repo) — removing it before reconfiguring", 1],
      [:step, "Stopping + uninstalling the existing runner service", 1],
      [:spin, "Deregistering at owner/repo", 1],
      [:note, "Existing config: registration removed", 1],
      [:spin, "Minting a registration token", 1],
      [:step, "Configuring the runner (--replace)", 1],
      [:step, "Installing + starting the runner service as runner", 1],
      [:note, "{{v}} Runner 'box' is registered and running — it should show Idle on the GitHub Runners page", 1],
    ]

    Cleanup
    FileUtils.remove_entry(dir)
  end

  test "remove_registration as another user clears the enrollment files as that user, through sudo, not with the operator's hands" do
    Given "an enrolled dir"
    dir = Dir.mktmpdir
    %w[.runner .credentials .credentials_rsaparams .service].each { |f| File.write(File.join(dir, f), "x") }
    exec = RecordingExecutor.new(&authed_responder)

    When
    outcome = Dev::RunnerSetup.remove_registration(dir, "owner/repo", executor: exec, ui: quiet, as_user: "runner")

    Then
    outcome == "registration removed"
    exec.systems.map { |call| call[:argv] } == [
      ["sudo", "-u", "runner", "-H", "rm", "-f", ".runner", ".credentials", ".credentials_rsaparams", ".service"],
    ]
    exec.calls.any? { |call| call[:argv] == ["sudo", "-u", "runner", "-H", "./config.sh", "remove", "--token", "RMTOKEN"] && call[:chdir] == dir }
    File.exist?(File.join(dir, ".runner"))

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
      ui: quiet, host_platform: "osx-arm64")
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
      ui: quiet, host_platform: "osx-arm64")
    setup.run

    Then "the installed service is uninstalled, the remove token comes from the old repo scope, " \
         "and the new registration from the org scope"
    uninstall_idx = exec.calls.index { |call| call[:argv] == ["./svc.sh", "uninstall"] }
    remove_idx = exec.calls.index { |call| call[:argv][0, 2] == ["./config.sh", "remove"] }
    register_idx = exec.calls.index { |call| call[:argv][0, 2] == ["./config.sh", "--url"] }
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
    setup = Dev::RunnerSetup.new(config: config, repo: "owner/repo", executor: exec, ui: quiet)

    When "running setup"
    setup.run

    Then "config.sh remove runs with the remove token before config.sh registers"
    remove = exec.calls.find { |call| call[:argv][0, 2] == ["./config.sh", "remove"] }
    remove[:argv] == ["./config.sh", "remove", "--token", "RMTOKEN"]
    remove[:chdir] == dir
    remove_idx = exec.calls.index { |call| call[:argv][0, 2] == ["./config.sh", "remove"] }
    register_idx = exec.calls.index { |call| call[:argv][0, 2] == ["./config.sh", "--url"] }
    remove_idx < register_idx

    Cleanup
    FileUtils.remove_entry(dir)
  end

  test "run tolerates config.sh remove failing for a registration the server no longer has (#238)" do
    Given "a configured dir whose registration GitHub has lost, so config.sh remove 404s"
    dir = Dir.mktmpdir
    config_sh = File.join(dir, "config.sh")
    File.write(config_sh, "#!/bin/bash\n")
    File.chmod(0o755, config_sh)
    File.write(File.join(dir, ".runner"), "\uFEFF#{JSON.generate("gitHubUrl" => "https://github.com/owner/repo")}")
    File.write(File.join(dir, ".credentials"), "stale")
    config = Dev::RunnerSetupConfig.new(labels: "ue-engine", dir: dir, name: "box")
    authed = authed_responder
    responder = lambda do |argv|
      next ["", "Failed: Removing runner from the server\n404 (Not Found)", false] if argv[0, 2] == ["./config.sh", "remove"]

      authed.call(argv)
    end
    exec = RecordingExecutor.new(&responder)
    ui = RecordingUi.new
    setup = Dev::RunnerSetup.new(config: config, repo: "owner/repo", executor: exec, ui: ui)

    When "running setup"
    setup.run

    Then "the gone registration is reported, the stale enrollment files are cleared, and registration proceeds"
    ui.rows.include?([:note, "Existing config: registration already gone from the server", 1])
    exec.systems.any? { |call| call[:argv][0, 2] == ["./config.sh", "--url"] }

    Cleanup
    FileUtils.remove_entry(dir)
  end

  test "run still aborts when config.sh remove fails for any other reason" do
    Given "a configured dir whose config.sh remove fails on the network"
    dir = Dir.mktmpdir
    config_sh = File.join(dir, "config.sh")
    File.write(config_sh, "#!/bin/bash\n")
    File.chmod(0o755, config_sh)
    File.write(File.join(dir, ".runner"), "\uFEFF#{JSON.generate("gitHubUrl" => "https://github.com/owner/repo")}")
    config = Dev::RunnerSetupConfig.new(labels: "ue-engine", dir: dir, name: "box")
    authed = authed_responder
    responder = lambda do |argv|
      next ["", "connect: network is unreachable", false] if argv[0, 2] == ["./config.sh", "remove"]

      authed.call(argv)
    end
    setup = Dev::RunnerSetup.new(config: config, repo: "owner/repo", executor: RecordingExecutor.new(&responder),
      ui: quiet)

    When "running setup"
    setup.run

    Then
    error = raises Dev::RunnerSetup::Error
    error.message.include?("network is unreachable")

    Cleanup
    FileUtils.remove_entry(dir)
  end

  test "run downloads the runner when config.sh is absent" do
    Given "an empty runner dir"
    dir = Dir.mktmpdir
    config = Dev::RunnerSetupConfig.new(labels: "ue-engine", dir: dir, version: "9.9.9")
    exec = RecordingExecutor.new(&authed_responder)
    ui = RecordingUi.new
    setup = Dev::RunnerSetup.new(config: config, repo: "owner/repo", executor: exec, ui: ui,
      host_platform: "linux-x64")

    When "running setup"
    setup.run

    Then "the pinned runner version is fetched and extracted, as one step under the enrollment's frame"
    curl = exec.systems.find { |call| call[:argv].first == "curl" }
    curl[:chdir] == dir
    curl[:argv].last == "https://github.com/actions/runner/releases/download/v9.9.9/actions-runner-linux-x64-9.9.9.tar.gz"
    exec.systems.any? { |call| call[:argv].first == "tar" }
    ui.rows.include?([:step, "Downloading actions-runner 9.9.9", 1])

    Cleanup
    FileUtils.remove_entry(dir)
  end

  test "run on macOS fetches the osx tarball and installs the service without sudo" do
    Given "an empty runner dir on an Apple Silicon host"
    dir = Dir.mktmpdir
    config = Dev::RunnerSetupConfig.new(labels: "macos,ue-editor", dir: dir, version: "9.9.9")
    exec = RecordingExecutor.new(&authed_responder)
    setup = Dev::RunnerSetup.new(config: config, repo: "owner/repo", executor: exec, ui: quiet,
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

  test "Executor#capture returns stdout, stderr, and success from a real process" do
    When "capturing a real shell command"
    out, err, ok = Dev::RunnerSetup::Executor.new.capture("sh", "-c", "echo out; echo err >&2")

    Then
    out == "out\n"
    err == "err\n"
    ok == true
  end

  test "Executor#capture reports a missing binary as a failure instead of raising" do
    When "capturing a command that does not exist"
    out, err, ok = Dev::RunnerSetup::Executor.new.capture("dev-test-missing-binary-xyz")

    Then "the ENOENT message rides the stderr slot"
    out == ""
    err.empty? == false
    ok == false
  end

  test "Executor#capture runs its child with colour off whatever the operator forced — gh colourises JSON on a pipe under CLICOLOR_FORCE / GH_FORCE_TTY, and every capture here is parsed (dev#544); #system is the operator's terminal and keeps their preference" do
    Given "an operator forcing colour, as bin/dev's UI tier is picked by"
    forced = { "CLICOLOR_FORCE" => "1", "GH_FORCE_TTY" => "1", "NO_COLOR" => nil }
    probe = ["sh", "-c", 'echo "${CLICOLOR_FORCE:-unset} ${GH_FORCE_TTY:-unset} ${NO_COLOR:-unset}"']

    When "capturing, and running, a child that reports those variables"
    captured, streamed = with_env(forced) do
      out, _err, _ok = Dev::RunnerSetup::Executor.new.capture(*probe)
      [out.strip, `#{probe.map { |word| "'#{word.gsub("'", "'\\\\''")}'" }.join(" ")}`.strip]
    end

    Then "the capture saw none of the forcing and NO_COLOR; a plain child saw what the operator set"
    captured == "unset unset 1"
    streamed == "1 1 unset"
  end

  test "Executor#system runs a real process, honoring chdir" do
    Given "a temp working directory"
    dir = Dir.mktmpdir("runner-setup-exec-")

    When "running real commands"
    ok = Dev::RunnerSetup::Executor.new.system("sh", "-c", "test \"$(pwd)\" = \"$1\"", "--", File.realpath(dir), chdir: dir)
    failed = Dev::RunnerSetup::Executor.new.system("sh", "-c", "exit 1")

    Then
    ok == true
    failed == false

    Cleanup
    FileUtils.rm_rf(dir)
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/runner_discovery"
require "dev/runner_teardown"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::RunnerTeardownTest < Minitest::Test
  # Records every CLI invocation (system and capture alike, in order) and
  # answers captures from a responder, so a teardown runs end to end
  # against real tempdir runner dirs without svc.sh, config.sh or gh.
  class RecordingExecutor
    attr_reader :calls

    def initialize(&capture_responder)
      @capture_responder = capture_responder
      @calls = []
    end

    def capture(*argv, chdir: nil)
      @calls << { argv: argv, chdir: chdir }
      @capture_responder ? @capture_responder.call(argv) : ["", "", true]
    end

    def system(*argv, chdir: nil)
      @calls << { argv: argv, chdir: chdir }
      true
    end
  end

  # gh mints a remove token; everything else succeeds.
  def minting_responder
    lambda do |argv|
      next ["RMTOKEN\n", "", true] if argv.any? { |arg| arg.include?("remove-token") }

      ["", "", true]
    end
  end

  # --- resolution -------------------------------------------------------

  test "resolve by scope finds the one enrollment serving it" do
    Given "one enrollment per scope"
    home = Dir.mktmpdir
    dir = write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs/cellbound-3d", name: "JPSFF")

    When "resolving the scope"
    enrollment = build_teardown(home: home).resolve("JPDuchesne/snappy")

    Then
    enrollment.dir == dir
  end

  test "resolve by dir — #{form} — names the enrollment living there, scope-blind" do
    Given "two enrollments for one scope in two dirs"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner", scope: "JPDuchesne/snappy", name: "JPSFF")
    expected = write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    reference = form == "absolute" ? expected : "~/actions-runner-snappy"

    When "resolving the dir"
    enrollment = build_teardown(home: home).resolve(reference)

    Then
    enrollment.dir == expected

    Where
    form         | _
    "absolute"   | nil
    "~-relative" | nil
  end

  test "resolve refuses an ambiguous scope, listing the dirs so the operator can name one" do
    Given "two enrollments for one scope"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner", scope: "JPDuchesne/snappy", name: "JPSFF")
    write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")

    When "resolving the scope"
    build_teardown(home: home).resolve("JPDuchesne/snappy")

    Then
    error = raises Dev::RunnerTeardown::AmbiguousEnrollmentError
    error.message.include?("~/actions-runner, ~/actions-runner-snappy")
  end

  test "resolve raises when nothing on this host matches #{reference.inspect}" do
    Given "one enrollment"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")

    When "resolving something else"
    build_teardown(home: home).resolve(reference)

    Then
    error = raises Dev::RunnerTeardown::NoSuchEnrollmentError
    error.message.include?(reference)

    Where
    reference                | _
    "d3mlabs"                | nil
    "~/actions-runner-fresh" | nil
    "/opt/nope"              | nil
  end

  # --- teardown ---------------------------------------------------------

  test "teardown! stops + uninstalls the service, deregisters at the enrollment's own scope, clears the four files" do
    Given "an enrollment with an installed service"
    home = Dir.mktmpdir
    dir = write_runner(home, "actions-runner", scope: "JPDuchesne/snappy", name: "JPSFF")
    %w[.credentials .credentials_rsaparams].each { |f| File.write(File.join(dir, f), "secret") }
    File.write(File.join(dir, ".service"), "actions.runner.JPDuchesne-snappy.JPSFF.service\n")
    File.write(File.join(dir, "config.sh"), "#!/bin/sh\n")
    exec = RecordingExecutor.new(&minting_responder)
    out = StringIO.new
    teardown = build_teardown(home: home, executor: exec, out: out)

    When "tearing it down"
    teardown.teardown!(teardown.resolve("~/actions-runner"))

    Then "service first (sudo on Linux), then a remove-token at the repo scope, then config.sh remove — all in the dir; " \
         "the enrollment files are gone, the binaries are not; the output says exactly what happened and where"
    exec.calls == [
      { argv: ["sudo", "./svc.sh", "stop"], chdir: dir },
      { argv: ["sudo", "./svc.sh", "uninstall"], chdir: dir },
      { argv: ["gh", "api", "-X", "POST", "repos/JPDuchesne/snappy/actions/runners/remove-token", "--jq", ".token"],
        chdir: nil },
      { argv: ["./config.sh", "remove", "--token", "RMTOKEN"], chdir: dir },
    ]
    %w[.runner .credentials .credentials_rsaparams .service].none? { |f| File.exist?(File.join(dir, f)) }
    File.exist?(File.join(dir, "config.sh"))
    out.string.include?(
      ">>> Unregistered JPSFF from JPDuchesne/snappy (~/actions-runner): service stopped and uninstalled, " \
      "registration removed, enrollment files cleared; binaries left in place.",
    )
  end

  test "teardown! skips the service steps when no service is installed, and says so" do
    Given "an enrollment without a .service marker"
    home = Dir.mktmpdir
    dir = write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    exec = RecordingExecutor.new(&minting_responder)
    out = StringIO.new
    teardown = build_teardown(home: home, executor: exec, out: out)

    When "tearing it down"
    teardown.teardown!(teardown.resolve("JPDuchesne/snappy"))

    Then "no svc.sh call; config.sh remove still runs"
    exec.calls.map { |c| c[:argv].first(2) } == [%w[gh api], ["./config.sh", "remove"]]
    out.string.include?("(~/actions-runner-snappy): no service installed, registration removed")
    !File.exist?(File.join(dir, ".runner"))
  end

  test "teardown! mints the remove token at an org scope's orgs/ endpoint" do
    Given "an org enrollment"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-ai", scope: "d3mlabs", name: "mac-box")
    exec = RecordingExecutor.new(&minting_responder)
    teardown = build_teardown(home: home, executor: exec)

    When "tearing it down"
    teardown.teardown!(teardown.resolve("d3mlabs"))

    Then
    exec.calls.fetch(0)[:argv].fetch(4) == "orgs/d3mlabs/actions/runners/remove-token"
  end

  test "teardown! on macOS drives svc.sh without sudo (a per-user LaunchAgent)" do
    Given "an enrollment with a service, on a Mac"
    home = Dir.mktmpdir
    dir = write_runner(home, "actions-runner-ai", scope: "d3mlabs", name: "mac-box")
    File.write(File.join(dir, ".service"), "actions.runner.d3mlabs.mac-box.plist\n")
    exec = RecordingExecutor.new(&minting_responder)
    teardown = build_teardown(home: home, executor: exec, host_platform: "osx-arm64")

    When "tearing it down"
    teardown.teardown!(teardown.resolve("d3mlabs"))

    Then
    exec.calls.first(2).map { |c| c[:argv] } == [["./svc.sh", "stop"], ["./svc.sh", "uninstall"]]
  end

  test "a registration the server no longer has counts as done: config.sh's 404 is reported, files still cleared" do
    Given "a config.sh remove that fails because the runner is gone server-side (superseded by --replace)"
    home = Dir.mktmpdir
    dir = write_runner(home, "actions-runner", scope: "JPDuchesne/snappy", name: "JPSFF")
    File.write(File.join(dir, ".credentials"), "secret")
    responder = lambda do |argv|
      next ["RMTOKEN\n", "", true] if argv.any? { |arg| arg.include?("remove-token") }
      next ["", "Failed: Removing runner from the server\nResponse status code does not indicate success: 404 (Not Found).", false] if argv.first == "./config.sh"

      ["", "", true]
    end
    out = StringIO.new
    teardown = build_teardown(home: home, executor: RecordingExecutor.new(&responder), out: out)

    When "tearing it down"
    teardown.teardown!(teardown.resolve("~/actions-runner"))

    Then "no raise; the files are gone; the output says the registration was already gone"
    !File.exist?(File.join(dir, ".runner"))
    !File.exist?(File.join(dir, ".credentials"))
    out.string.include?("registration already gone from the server")
  end

  test "any other config.sh remove failure is a TeardownFailedError carrying config.sh's output, files untouched" do
    Given "a config.sh remove that fails for a reason that is not a missing runner"
    home = Dir.mktmpdir
    dir = write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    responder = lambda do |argv|
      next ["RMTOKEN\n", "", true] if argv.any? { |arg| arg.include?("remove-token") }
      next ["", "Failed: Removing runner from the server\nconnect: network is unreachable", false] if argv.first == "./config.sh"

      ["", "", true]
    end
    teardown = build_teardown(home: home, executor: RecordingExecutor.new(&responder))

    When "tearing it down"
    teardown.teardown!(teardown.resolve("JPDuchesne/snappy"))

    Then
    error = raises Dev::RunnerTeardown::TeardownFailedError
    error.message.include?("network is unreachable")
    File.exist?(File.join(dir, ".runner"))
  end

  test "a service that will not stop or uninstall is a TeardownFailedError before anything is deregistered" do
    Given "an svc.sh whose uninstall fails"
    home = Dir.mktmpdir
    dir = write_runner(home, "actions-runner", scope: "JPDuchesne/snappy", name: "JPSFF")
    File.write(File.join(dir, ".service"), "unit\n")
    exec = RecordingExecutor.new(&minting_responder)
    exec.define_singleton_method(:system) do |*argv, chdir: nil|
      @calls << { argv: argv, chdir: chdir }
      argv.last != "uninstall"
    end
    teardown = build_teardown(home: home, executor: exec)

    When "tearing it down"
    teardown.teardown!(teardown.resolve("~/actions-runner"))

    Then "it stops at the service; config.sh remove never ran; the enrollment is intact"
    error = raises Dev::RunnerTeardown::TeardownFailedError
    error.message.include?("svc.sh uninstall")
    exec.calls.none? { |c| c[:argv].first == "./config.sh" }
    File.exist?(File.join(dir, ".service"))
  end

  test "a remove token that cannot be minted is a TeardownFailedError" do
    Given "a gh that cannot mint"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    responder = ->(_argv) { ["", "HTTP 404: Not Found (repo deleted)", false] }
    teardown = build_teardown(home: home, executor: RecordingExecutor.new(&responder))

    When "tearing it down"
    teardown.teardown!(teardown.resolve("JPDuchesne/snappy"))

    Then
    error = raises Dev::RunnerTeardown::TeardownFailedError
    error.message.include?("remove-token")
  end

  private

  def build_teardown(home:, executor: RecordingExecutor.new(&minting_responder), out: StringIO.new,
                     host_platform: "linux-x64")
    Dev::RunnerTeardown.new(
      discovery: Dev::RunnerDiscovery.new(home: home),
      executor: executor,
      out: out,
      host_platform: host_platform,
      home: home,
    )
  end

  # A .runner record the way config.sh writes it (UTF-8 BOM + JSON).
  def write_runner(home, dir_name, scope:, name:)
    dir = File.join(home, dir_name)
    FileUtils.mkdir_p(dir)
    record = { "agentName" => name, "gitHubUrl" => "https://github.com/#{scope}" }
    File.write(File.join(dir, ".runner"), "\uFEFF#{JSON.generate(record)}")
    dir
  end
end

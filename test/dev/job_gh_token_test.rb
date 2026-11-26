# typed: false
# frozen_string_literal: true

require "fileutils"
require "test_helper"
require "tmpdir"
require "dev/job_gh_token"
require "support/answering_ui"
require "support/recording_ui"

# The command boundary: svc.sh and gh answer as the test says, and every
# call is recorded with the env it was spawned under — the token must ride
# the env, never argv.
class RecordingJobTokenExecutor
  attr_reader :systems, :captures

  def initialize(svc_ok: true, gh_ok: true)
    @svc_ok = svc_ok
    @gh_ok = gh_ok
    @systems = []
    @captures = []
  end

  def system(*argv, chdir: nil)
    @systems << [argv, chdir]
    argv.any? { |word| word.end_with?("svc.sh") } ? @svc_ok : true
  end

  def capture(*argv, chdir: nil, stdin: nil, env: {})
    @captures << [argv, env]
    @gh_ok ? ["Logged in", "", true] : ["", "The value of the GH_TOKEN environment variable is being used for authentication.\nX invalid token", false]
  end
end

transform!(RSpock::AST::Transformation)
class Dev::JobGhTokenTest < Minitest::Test
  test "a slot without the token gets it: asked once, checked through gh's env, written 0600 beside the runner's own lines, the service bounced in the OS's svc.sh dialect: #{platform}" do
    Given "an enrolled slot with its service and no credential for its jobs"
    dir = runner_dir(env: "LANG=C\n", service: true)
    exec = RecordingJobTokenExecutor.new
    ui = AnsweringUi.new(secret: "ghp_machine\n")

    When
    Dev::JobGhToken.new(executor: exec, host_platform: platform, ui: ui).ensure!(runner_dir: dir)

    Then "the token is the last line of .env, readable by the owner alone"
    File.read(File.join(dir, ".env")) == "LANG=C\nGH_TOKEN=ghp_machine\n"
    format("%o", File.stat(File.join(dir, ".env")).mode & 0o777) == "600"
    Dev::JobGhToken.present?(dir)
    # gh checked the token from its env, not its argv; the service was bounced
    exec.captures == [[["gh", "auth", "status"], { "GH_TOKEN" => "ghp_machine" }]]
    exec.systems == [[stop, dir], [start, dir]]
    # the question named what the token is for and what it must carry
    ui.secrets_asked.length == 1
    ui.secrets_asked.fetch(0).include?("every job on this host fetches with it")
    ui.secrets_asked.fetch(0).include?(Dev::RunnerUser.token_hint)
    ui.rows.any? { |kind, text, _depth| kind == :step && text.start_with?("Giving the jobs of #{dir} a gh credential") }

    Where
    platform      | stop                          | start
    "linux-x64"   | ["sudo", "./svc.sh", "stop"]  | ["sudo", "./svc.sh", "start"]
    "osx-arm64"   | ["./svc.sh", "stop"]          | ["./svc.sh", "start"]
  end

  test "a family's slots share one answer: the second dir is written without a second question" do
    Given
    first = runner_dir(env: "LANG=C\n", service: true)
    second = runner_dir(env: "LANG=C\n", service: true)
    exec = RecordingJobTokenExecutor.new
    ui = AnsweringUi.new(secret: "ghp_machine")
    token = Dev::JobGhToken.new(executor: exec, host_platform: "osx-arm64", ui: ui)

    When
    token.ensure!(runner_dir: first)
    token.ensure!(runner_dir: second)

    Then
    ui.secrets_asked.length == 1
    exec.captures.length == 1
    File.read(File.join(second, ".env")) == "LANG=C\nGH_TOKEN=ghp_machine\n"
  end

  test "a slot already carrying the token is left as it is: nothing asked, nothing run" do
    Given
    dir = runner_dir(env: "LANG=C\nGH_TOKEN=ghp_old\n", service: true)
    exec = RecordingJobTokenExecutor.new
    ui = AnsweringUi.new(secret: "ghp_new")

    When
    Dev::JobGhToken.new(executor: exec, host_platform: "osx-arm64", ui: ui).ensure!(runner_dir: dir)

    Then
    File.read(File.join(dir, ".env")) == "LANG=C\nGH_TOKEN=ghp_old\n"
    ui.secrets_asked.empty?
    exec.captures.empty?
    exec.systems.empty?
    ui.rows.empty?
  end

  test "a dir with no service — register, before svc.sh install — is written without a bounce, and a dir with no .env gets one" do
    Given
    dir = runner_dir(env: nil, service: false)
    exec = RecordingJobTokenExecutor.new

    When
    Dev::JobGhToken.new(executor: exec, host_platform: "osx-arm64", ui: AnsweringUi.new(secret: "ghp_machine")).ensure!(runner_dir: dir)

    Then
    File.read(File.join(dir, ".env")) == "GH_TOKEN=ghp_machine\n"
    exec.systems.empty?
  end

  test "headless — the Ui answers nothing — is TokenRequiredError naming the file, the key and the bounce, with nothing written" do
    Given
    dir = runner_dir(env: "LANG=C\n", service: true)
    exec = RecordingJobTokenExecutor.new

    When
    error = assert_raises(Dev::JobGhToken::TokenRequiredError) do
      Dev::JobGhToken.new(executor: exec, host_platform: "osx-arm64", ui: RecordingUi.new).ensure!(runner_dir: dir)
    end

    Then
    error.message.include?("GH_TOKEN=<token>")
    error.message.include?("#{dir}/.env")
    error.message.include?("./svc.sh stop && ./svc.sh start")
    error.message.include?(Dev::RunnerUser.token_hint)
    File.read(File.join(dir, ".env")) == "LANG=C\n"
    exec.systems.empty?
  end

  test "a token gh refuses is TokenRequiredError carrying gh's words, with nothing written" do
    Given
    dir = runner_dir(env: "LANG=C\n", service: true)
    exec = RecordingJobTokenExecutor.new(gh_ok: false)

    When
    error = assert_raises(Dev::JobGhToken::TokenRequiredError) do
      Dev::JobGhToken.new(executor: exec, host_platform: "osx-arm64", ui: AnsweringUi.new(secret: "bad")).ensure!(runner_dir: dir)
    end

    Then
    error.message.include?("gh did not accept the token")
    error.message.include?("invalid token")
    !error.message.include?("environment variable is being used")
    File.read(File.join(dir, ".env")) == "LANG=C\n"
    exec.systems.empty?
  end

  test "svc.sh refusing is ServiceRestartError" do
    Given
    dir = runner_dir(env: "LANG=C\n", service: true)
    exec = RecordingJobTokenExecutor.new(svc_ok: false)

    When
    error = assert_raises(Dev::JobGhToken::ServiceRestartError) do
      Dev::JobGhToken.new(executor: exec, host_platform: "osx-arm64", ui: AnsweringUi.new(secret: "ghp_machine")).ensure!(runner_dir: dir)
    end

    Then
    error.message == "svc.sh stop failed in #{dir}"
  end

  test "present? reads the key alone — #{what}" do
    Given
    dir = runner_dir(env: env, service: false)

    Expect
    Dev::JobGhToken.present?(dir) == present

    Where
    what                 | env                              | present
    "the key"            | "LANG=C\nGH_TOKEN=x\n"           | true
    "the runner's lines" | "LANG=C\n"                       | false
    "a look-alike key"   | "GH_TOKEN_FILE=/x\nMY_GH_TOKEN=y\n" | false
    "no .env"            | nil | false
  end

  private

  def runner_dir(env:, service:)
    dir = Dir.mktmpdir("dev-job-token-")
    File.write(File.join(dir, ".env"), env) if env
    File.write(File.join(dir, ".service"), "actions.runner.d3mlabs.mac-agent\n") if service
    dir
  end
end

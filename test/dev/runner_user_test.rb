# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/privileged_steps"
require "dev/runner_user"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::RunnerUserTest < Minitest::Test
  # Records sudo steps; every one succeeds.
  class RecordingSteps
    attr_reader :runs

    def initialize
      @runs = []
    end

    def run(*cmd)
      @runs << cmd
      true
    end
  end

  # Answers `sudo -u <user> -H gh auth status` from a flag; records calls.
  class GhExecutor
    attr_reader :calls

    def initialize(logged_in:)
      @logged_in = logged_in
      @calls = []
    end

    def capture(*argv, chdir: nil)
      @calls << argv
      @logged_in ? ["Logged in to github.com account d3mlabs-buildhost\n", "", true] : ["", "You are not logged into any GitHub hosts.", false]
    end
  end

  def setup
    @executor = RecordingSteps.new
    @out = StringIO.new
  end

  test "for_host is the host rule: a runner user on Linux (runner by default, --as overrides the name), none elsewhere" do
    Expect
    Dev::RunnerUser.for_host(host_os: "linux")&.name == "runner"
    Dev::RunnerUser.for_host(host_os: "linux", name: "ci")&.name == "ci"
    Dev::RunnerUser.for_host(host_os: "darwin").nil?
    Dev::RunnerUser.for_host(host_os: "darwin", name: "ci").nil?
  end

  test "an absent runner user is created in one sudo session: the groups it needs, a login user with a home the operator can read, no password" do
    Given "no such user on the host"
    user = runner_user(homes: {})

    When
    user.converge!

    Then "the session, the groups (idempotent), the user, the home mode — each its own argv"
    @executor.runs == [
      %w[sudo -v],
      %w[sudo groupadd -f docker],
      %w[sudo groupadd -f dev],
      %w[sudo useradd -m -s /bin/bash -G docker,dev runner],
      %w[sudo chmod 0755 /home/runner],
    ]
    @out.string.include?(">>> Creating the runner user runner (one sudo prompt) ...")
  end

  test "a present runner user is converged: group membership only, no useradd, no chmod" do
    Given "the user exists with a home"
    user = runner_user(homes: { "runner" => "/home/runner" })

    When
    user.converge!

    Then
    @executor.runs == [
      %w[sudo -v],
      %w[sudo groupadd -f docker],
      %w[sudo groupadd -f dev],
      %w[sudo usermod -aG docker,dev runner],
    ]
    @out.string.empty?
  end

  test "home is the user's passwd entry when it exists, /home/<name> before it does" do
    Expect
    runner_user(homes: { "runner" => "/srv/runner" }).home == "/srv/runner"
    runner_user(homes: {}).home == "/home/runner"
    runner_user(homes: { "runner" => "/srv/runner" }).exists?
    !runner_user(homes: {}).exists?
  end

  test "by default the passwd lookup is the host's: this user's own home, and no home for a name passwd does not know" do
    Given "this test's own user, and a name no host has"
    own = Etc.getpwuid(Process.uid)
    unknown = "no-such-user-#{Process.pid}"

    Expect
    Dev::RunnerUser.new(name: own.name).home == own.dir
    Dev::RunnerUser.new(name: own.name).exists?
    !Dev::RunnerUser.new(name: unknown).exists?
    Dev::RunnerUser.passwd_home(unknown).nil?
  end

  test "ensure_gh_authenticated! asks gh as the runner user, through sudo, and is silent when it is logged in" do
    Given
    gh = GhExecutor.new(logged_in: true)
    user = runner_user(homes: { "runner" => "/home/runner" }, gh: gh)

    When
    user.ensure_gh_authenticated!

    Then
    gh.calls == [%w[sudo -u runner -H gh auth status]]
  end

  test "a runner user with no gh login stops register with the one command that logs it in — the token on stdin, never argv" do
    Given
    gh = GhExecutor.new(logged_in: false)
    user = runner_user(homes: { "runner" => "/home/runner" }, gh: gh)
    error = assert_raises(Dev::RunnerUser::GhLoginRequiredError) { user.ensure_gh_authenticated! }

    Expect
    error.message.include?("runner has no GitHub login")
    error.message.include?("sudo -iu runner gh auth login --with-token")
    error.message.include?("paste the machine user's token")
    error.message.include?("re-run dev runner register")
    user.login_command == "sudo -iu runner gh auth login --with-token"
  end

  test "the sudo prefix that touches the runner user's files as that user" do
    Expect
    runner_user(homes: {}).sudo_argv("mkdir", "-p", "/home/runner/x") == %w[sudo -u runner -H mkdir -p /home/runner/x]
  end

  test "the default runner user is runner, in docker and the data root's group" do
    Expect
    Dev::RunnerUser::DEFAULT_NAME == "runner"
    Dev::RunnerUser::GROUPS == ["docker", Dev::LinuxDataRootProvisioner::GROUP]
  end

  private

  def runner_user(homes:, gh: GhExecutor.new(logged_in: true), name: "runner")
    steps = Dev::PrivilegedSteps.new(executor: @executor, tty: true, purpose: "create the runner user")
    Dev::RunnerUser.new(name: name, steps: steps, executor: gh, out: @out, home_of: ->(user) { homes[user] })
  end
end

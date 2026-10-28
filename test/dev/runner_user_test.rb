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

  # Answers `gh auth status` from a flag — flipped to logged-in by a
  # `gh auth login --with-token` whose stdin carries the accepted token;
  # records every call with what rode its stdin.
  class GhExecutor
    attr_reader :calls, :stdins

    def initialize(logged_in:, accepts: "ghp_good")
      @logged_in = logged_in
      @accepts = accepts
      @calls = []
      @stdins = []
    end

    def capture(*argv, chdir: nil, stdin: nil)
      @calls << argv
      @stdins << stdin
      if argv.include?("login")
        @logged_in = (stdin == @accepts)
        return @logged_in ? ["", "✓ Logged in as d3mlabs-buildhost", true] : ["", "error validating token", false]
      end
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

  test "with Homebrew on the host, converge! gives every login shell its shellenv — so `sudo -iu runner gh` finds the gh brew installed" do
    Given "brew at the operator's prefix"
    user = runner_user(homes: { "runner" => "/home/runner" }, brew: "/home/linuxbrew/.linuxbrew/bin/brew")

    When
    user.converge!

    Then "one root-owned profile.d file, installed from a staged copy, after the groups"
    @executor.runs.map(&:first) == ["sudo"] * 5
    @executor.runs.fetch(4).first(4) == %w[sudo install -m 0644]
    @executor.runs.fetch(4).last == "/etc/profile.d/linuxbrew.sh"
    File.read(@executor.runs.fetch(4).fetch(4)) == "eval \"$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)\"\n"
  end

  test "brew is the one the operator's PATH names, never its symlink target: Linuxbrew's bin/brew points into Homebrew/bin, and brew's prefix is where the link lives" do
    Given "a PATH with a bin dir whose brew is a symlink into the repository under the prefix (Linuxbrew's layout)"
    prefix = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(prefix, "Homebrew", "bin"))
    File.write(File.join(prefix, "Homebrew", "bin", "brew"), "#!/bin/sh\n")
    File.chmod(0o755, File.join(prefix, "Homebrew", "bin", "brew"))
    FileUtils.mkdir_p(File.join(prefix, "bin"))
    File.symlink(File.join(prefix, "Homebrew", "bin", "brew"), File.join(prefix, "bin", "brew"))
    empty = Dir.mktmpdir

    Expect
    Dev::RunnerUser.brew_path(env_path: "#{empty}:#{prefix}/bin") == File.join(prefix, "bin", "brew")
    Dev::RunnerUser.host_path(brew: Dev::RunnerUser.brew_path(env_path: "#{prefix}/bin")) == "#{prefix}/bin:#{prefix}/sbin:#{Dev::RunnerUser::SYSTEM_PATH}"
    Dev::RunnerUser.brew_path(env_path: empty).nil?
    Dev::RunnerUser.brew_path(env_path: "").nil?
  end

  test "the runner user's PATH is deliberate: brew's bin and sbin ahead of the system's, nothing of the operator's; without brew, the system's alone" do
    Expect
    Dev::RunnerUser.host_path(brew: "/home/linuxbrew/.linuxbrew/bin/brew") ==
      "/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    Dev::RunnerUser.host_path(brew: nil) == "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
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
    gh.calls == [%w[sudo -u runner -H env PATH=/opt/brew/bin:/usr/bin gh auth status]]
  end

  test "a runner user with no gh login, and nothing to ask with (headless), stops register with the one command that logs it in — the token on stdin, never argv" do
    Given
    gh = GhExecutor.new(logged_in: false)
    user = runner_user(homes: { "runner" => "/home/runner" }, gh: gh)
    error = assert_raises(Dev::RunnerUser::GhLoginRequiredError) { user.ensure_gh_authenticated! }

    Expect
    error.message.include?("runner has no GitHub login")
    error.message.include?("sudo -iu runner gh auth login --with-token")
    error.message.include?("paste the machine user's token")
    error.message.include?("re-run dev runner register")
    Dev::RunnerUser::TOKEN_SCOPES.all? { |scope| error.message.include?(scope) }
    user.login_command == "sudo -iu runner gh auth login --with-token"
    gh.calls.none?(&logs_in)
  end

  test "with something to ask with, a missing login is asked for — hidden — and the answer rides gh's stdin as the runner user; the status is re-read after" do
    Given "no login, and an asker that answers the token"
    gh = GhExecutor.new(logged_in: false, accepts: "ghp_good")
    user = runner_user(homes: { "runner" => "/home/runner" }, gh: gh)
    questions = []
    ask = ->(question) do
      questions << question
      "ghp_good"
    end

    When
    user.ensure_gh_authenticated!(ask: ask)

    Then "one question naming the identity and what the token must be; status, login (token on stdin only), status"
    questions.size == 1
    questions.fetch(0).include?("runner has no GitHub login")
    questions.fetch(0).include?("machine user's token")
    questions.fetch(0).include?("repo, read:org, read:packages")
    gh.calls.map(&last_three) == ["gh auth status", "auth login --with-token", "gh auth status"]
    gh.calls.fetch(1) == %w[sudo -u runner -H env PATH=/opt/brew/bin:/usr/bin gh auth login --with-token]
    gh.stdins == [nil, "ghp_good", nil]
    gh.calls.flatten.grep(/ghp_/).empty?
  end

  test "an asker that answers nothing (declined, or no terminal behind it) falls back to the headless message; a token gh refuses says so, names the scopes it needs and the command" do
    Given
    declined = GhExecutor.new(logged_in: false)
    refused = GhExecutor.new(logged_in: false, accepts: "ghp_good")
    user_declined = runner_user(homes: { "runner" => "/home/runner" }, gh: declined)
    user_refused = runner_user(homes: { "runner" => "/home/runner" }, gh: refused)
    nothing = assert_raises(Dev::RunnerUser::GhLoginRequiredError) { user_declined.ensure_gh_authenticated!(ask: ->(_q) { "" }) }
    bad = assert_raises(Dev::RunnerUser::GhLoginRequiredError) { user_refused.ensure_gh_authenticated!(ask: ->(_q) { "ghp_bad" }) }

    Expect
    nothing.message.include?("sudo -iu runner gh auth login --with-token")
    declined.calls.none?(&logs_in)
    bad.message.include?("gh did not accept the token")
    bad.message.include?("error validating token")
    bad.message.include?("classic token with repo, read:org, read:packages")
    bad.message.include?("sudo -iu runner gh auth login --with-token")
    refused.calls.count(&logs_in) == 1
  end

  test "the sudo prefix that runs a command as the runner user, in its own home, on the host's PATH — not sudo's, not the operator's" do
    Expect
    runner_user(homes: {}).sudo_argv("mkdir", "-p", "/home/runner/x") == %w[sudo -u runner -H env PATH=/opt/brew/bin:/usr/bin mkdir -p /home/runner/x]
    runner_user(homes: {}).path == "/opt/brew/bin:/usr/bin"
  end

  test "the default runner user is runner, in docker and the data root's group" do
    Expect
    Dev::RunnerUser::DEFAULT_NAME == "runner"
    Dev::RunnerUser::GROUPS == ["docker", Dev::LinuxDataRootProvisioner::GROUP]
  end

  private

  # Lambdas, not blocks: a one-parameter block is emitted as |argv,| by the
  # transform (rspockframework/ast-transform#21) and destructures an argv.
  def logs_in = ->(argv) { argv.include?("login") }
  def last_three = ->(argv) { argv.last(3).join(" ") }

  def runner_user(homes:, gh: GhExecutor.new(logged_in: true), name: "runner", brew: nil)
    steps = Dev::PrivilegedSteps.new(executor: @executor, tty: true, purpose: "create the runner user")
    Dev::RunnerUser.new(name: name, steps: steps, executor: gh, out: @out, home_of: ->(user) { homes[user] },
      brew: brew, path: "/opt/brew/bin:/usr/bin")
  end
end

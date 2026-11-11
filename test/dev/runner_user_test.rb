# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/privileged_steps"
require "dev/runner_user"
require "stringio"
require "support/recording_ui"

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
  # records every call with what rode its stdin. The streamed `brew trust`
  # (`system`) answers from `trusts:` — false for a brew without the command.
  class GhExecutor
    attr_reader :calls, :stdins

    def initialize(logged_in:, accepts: "ghp_good", trusts: true)
      @logged_in = logged_in
      @accepts = accepts
      @trusts = trusts
      @calls = []
      @stdins = []
    end

    def system(*argv, chdir: nil)
      @calls << argv
      @stdins << nil
      @trusts
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
    @ui = RecordingUi.new
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
    @ui.rows == [[:step, "Creating the runner user runner (one sudo prompt)", 0]]
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

  # dev#337: the toolchain is the runner user's by rule; a prefix owned by
  # anyone else is converged like every other host fact — one step, said
  # out loud, no question.
  test "a toolchain owned by someone else is handed to the runner user as one more converged step; one already the runner user's is left alone" do
    Given "a present runner user, Linuxbrew owned by the operator; and the same owned by the runner user"
    linuxbrew = "/home/linuxbrew/.linuxbrew/bin/brew"
    drifted = runner_user(homes: { "runner" => "/home/runner" }, brew: linuxbrew, owner_of: ->(_path) { "jpduchesne" })
    drifted.converge!
    drifted_runs = @executor.runs.dup
    drifted_rows = @ui.rows.dup
    @executor.runs.clear
    @ui.events.clear
    owned = runner_user(homes: { "runner" => "/home/runner" }, brew: linuxbrew, owner_of: ->(_path) { "runner" })
    owned.converge!

    Expect "the chown after the profile.d file, both roots, announced; nothing of the kind when nothing drifted"
    drifted_runs.last == %w[sudo chown -R runner:runner /home/linuxbrew/.linuxbrew /home/linuxbrew]
    drifted_runs.count(&chowns) == 1
    drifted_rows.include?([:step, "Handing the toolchain /home/linuxbrew/.linuxbrew (owned by jpduchesne) to runner: jobs upgrade dev through it; " \
                                  "brew as jpduchesne becomes `sudo -iu runner brew ...`", 0])
    @executor.runs.none?(&chowns)
    @ui.rows.none? { |_kind, text, _depth| text.include?("Handing the toolchain") }
  end

  # Homebrew 7 loads nothing from a tap a user has not trusted, and trust
  # is per user (~/.homebrew/trust.json): the operator's does not carry
  # to the runner user, whose first `brew upgrade` of dev in a job was
  # refused the deployment formula (dev#310 step 5). The step itself is
  # TapTrust's (shared with the macOS agent bootstrap, dev#374); what is
  # the runner user's here is how it runs — as that user, on the host PATH.
  test "with brew and a deployment tap, converge! has the runner user trust the tap — as that user, on the host PATH, streamed; a brew without `trust` is a warning, not a stop" do
    Given "a runner user on a host with brew and the org tap; and one whose brew predates `brew trust`"
    trusting = GhExecutor.new(logged_in: true)
    user = runner_user(homes: { "runner" => "/home/runner" }, brew: "/home/linuxbrew/.linuxbrew/bin/brew", gh: trusting, tap: org_tap)
    user.converge!
    first_rows = @ui.rows.dup
    @ui.events.clear
    old = GhExecutor.new(logged_in: true, trusts: false)
    runner_user(homes: { "runner" => "/home/runner" }, brew: "/home/linuxbrew/.linuxbrew/bin/brew", gh: old, tap: org_tap).converge!

    Expect "brew trust as the runner user, on the host PATH, the brew dev found; the refusal is one warning naming the by-hand command"
    trusting.calls.count(&trusts) == 1
    trusting.calls.find(&trusts) == %w[sudo -u runner -H env -C / PATH=/opt/brew/bin:/usr/bin env HOMEBREW_NO_AUTO_UPDATE=1 /home/linuxbrew/.linuxbrew/bin/brew trust --tap d3mlabs/d3mlabs]
    first_rows.include?([:step, "Trusting the tap d3mlabs/d3mlabs for runner (brew loads nothing from a tap its user has not trusted)", 0])
    first_rows.none? { |_kind, text, _depth| text.include?("could not trust") }
    @ui.rows.any? { |kind, text, _depth| kind == :note && text.start_with?("{{x}} could not trust the tap d3mlabs/d3mlabs for runner") }
    @ui.rows.any? { |_kind, text, _depth| text.include?("sudo -iu runner brew trust --tap d3mlabs/d3mlabs") }
  end

  test "no tap to trust without a deployment tap, or without brew" do
    Given
    bare = GhExecutor.new(logged_in: true)
    runner_user(homes: { "runner" => "/home/runner" }, brew: "/home/linuxbrew/.linuxbrew/bin/brew", gh: bare, tap: nil).converge!
    brewless = GhExecutor.new(logged_in: true)
    runner_user(homes: { "runner" => "/home/runner" }, brew: nil, gh: brewless, tap: org_tap).converge!

    Expect
    bare.calls.none?(&trusts)
    brewless.calls.none?(&trusts)
  end

  # dev#568: the host's brew is `<prefix>/bin/brew` under the one prefix dev
  # resolves (Settings.brew_prefix), not whatever the operator's PATH names
  # — PATH is shell state, and a register run from a shell without brew on
  # it would hand the runner no shellenv, no toolchain, no brew edge. The
  # prefix's own `bin/brew`, never its realpath: Linuxbrew's is a link into
  # `<prefix>/Homebrew/bin`, and brew takes its prefix from the path it is
  # invoked by.
  test "the host's brew is <prefix>/bin/brew under the resolved prefix — #{what}" do
    Given "a prefix #{what}"
    dir = Dir.mktmpdir
    prefix = File.join(dir, "prefix")
    send(layout, prefix)
    brew = Dev::RunnerUser.brew_path(prefix: resolved ? prefix : nil)

    Expect "the link itself, and a PATH built on the prefix it lives in"
    brew == (found ? File.join(prefix, "bin", "brew") : nil)
    Dev::RunnerUser.host_path(brew: brew) == (found ? "#{prefix}/bin:#{prefix}/sbin:#{Dev::RunnerUser::SYSTEM_PATH}" : Dev::RunnerUser::SYSTEM_PATH)

    Cleanup
    FileUtils.rm_rf(dir)

    Where
    what                                  | resolved | layout        | found
    "with brew at bin/brew"               | true     | :brew_at      | true
    "linking bin/brew into Homebrew/bin"  | true     | :linuxbrew_at | true
    "without a bin/brew"                  | true     | :empty_bin_at | false
    "unresolved (a machine without brew)" | false    | :empty_bin_at | false
  end

  # macOS's layout: brew itself at <prefix>/bin/brew.
  def brew_at(prefix)
    executable(File.join(prefix, "bin", "brew"))
  end

  # Linuxbrew's layout: <prefix>/bin/brew a link into <prefix>/Homebrew/bin.
  def linuxbrew_at(prefix)
    executable(File.join(prefix, "Homebrew", "bin", "brew"))
    FileUtils.mkdir_p(File.join(prefix, "bin"))
    File.symlink(File.join("..", "Homebrew", "bin", "brew"), File.join(prefix, "bin", "brew"))
  end

  def empty_bin_at(prefix)
    FileUtils.mkdir_p(File.join(prefix, "bin"))
  end

  def executable(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#!/bin/sh\n")
    FileUtils.chmod(0o755, path)
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
    @ui.rows == [[:step, "Converging the runner user runner (groups, profile)", 0]]
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
    gh.calls == [%w[sudo -u runner -H env -C / PATH=/opt/brew/bin:/usr/bin gh auth status]]
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
    ui = SecretAnsweringUi.new("ghp_good")
    user = runner_user(homes: { "runner" => "/home/runner" }, gh: gh, ui: ui)

    When
    user.ensure_gh_authenticated!

    Then "one question, hidden, naming the identity and what the token must be; status, login (token on stdin only), status"
    ui.secrets_asked.size == 1
    ui.secrets_asked.fetch(0).include?("runner has no GitHub login")
    ui.secrets_asked.fetch(0).include?("machine user's token")
    ui.secrets_asked.fetch(0).include?("repo, read:org, read:packages")
    gh.calls.map(&last_three) == ["gh auth status", "auth login --with-token", "gh auth status"]
    gh.calls.fetch(1) == %w[sudo -u runner -H env -C / PATH=/opt/brew/bin:/usr/bin gh auth login --with-token]
    gh.stdins == [nil, "ghp_good", nil]
    gh.calls.flatten.grep(/ghp_/).empty?
  end

  test "a terminal that answers nothing (declined, or none behind it — NoUi answers nil) falls back to the headless message; a token gh refuses says so, names the scopes it needs and the command" do
    Given
    declined = GhExecutor.new(logged_in: false)
    refused = GhExecutor.new(logged_in: false, accepts: "ghp_good")
    user_declined = runner_user(homes: { "runner" => "/home/runner" }, gh: declined, ui: SecretAnsweringUi.new(""))
    user_refused = runner_user(homes: { "runner" => "/home/runner" }, gh: refused, ui: SecretAnsweringUi.new("ghp_bad"))
    nothing = assert_raises(Dev::RunnerUser::GhLoginRequiredError) { user_declined.ensure_gh_authenticated! }
    bad = assert_raises(Dev::RunnerUser::GhLoginRequiredError) { user_refused.ensure_gh_authenticated! }

    Expect
    nothing.message.include?("sudo -iu runner gh auth login --with-token")
    declined.calls.none?(&logs_in)
    bad.message.include?("gh did not accept the token")
    bad.message.include?("error validating token")
    bad.message.include?("classic token with repo, read:org, read:packages")
    bad.message.include?("sudo -iu runner gh auth login --with-token")
    refused.calls.count(&logs_in) == 1
  end

  test "the sudo prefix that runs a command as the runner user, in its own home, on the host's PATH — not sudo's, not the operator's — and from a cwd it can read, never the operator's (dev#493)" do
    Expect
    runner_user(homes: {}).sudo_argv("mkdir", "-p", "/home/runner/x") == %w[sudo -u runner -H env -C / PATH=/opt/brew/bin:/usr/bin mkdir -p /home/runner/x]
    runner_user(homes: {}).path == "/opt/brew/bin:/usr/bin"
  end

  # dev#348: an inspector must never prompt; `-n` makes a refusal a fact
  # instead of a swallowed password prompt.
  test "the non-interactive prefix refuses rather than prompts, and the one command that answers for the login by hand" do
    Expect
    runner_user(homes: {}).probe_argv("gh", "auth", "status") == %w[sudo -n -u runner -H env -C / PATH=/opt/brew/bin:/usr/bin gh auth status]
    runner_user(homes: {}).status_command == "sudo -iu runner gh auth status"
  end

  test "the default runner user is runner, in docker and the data root's group" do
    Expect
    Dev::RunnerUser::DEFAULT_NAME == "runner"
    Dev::RunnerUser::GROUPS == ["docker", Dev::DataRoot::GROUP]
  end

  # dev#337: the toolchain is brew's prefix (and, on Linuxbrew, the home it
  # sits in); the runner user owns it, or the host has drifted.
  test "the toolchain is brew's prefix plus the Linuxbrew home above it; the runner user owns it, or not, by the prefix's owner" do
    Given "a Linuxbrew prefix owned by the operator, the same owned by the runner user, and a host without brew"
    linuxbrew = "/home/linuxbrew/.linuxbrew/bin/brew"
    operators = runner_user(homes: {}, brew: linuxbrew, owner_of: ->(_path) { "jpduchesne" })
    runners = runner_user(homes: {}, brew: linuxbrew, owner_of: ->(_path) { "runner" })
    brewless = runner_user(homes: {}, brew: nil, owner_of: ->(_path) { "jpduchesne" })
    elsewhere = runner_user(homes: {}, brew: "/opt/brew/bin/brew", owner_of: ->(_path) { "jpduchesne" })

    Expect "the roots, the owner, the verdict, and the one command that fixes drift"
    operators.toolchain_roots == ["/home/linuxbrew/.linuxbrew", "/home/linuxbrew"]
    elsewhere.toolchain_roots == ["/opt/brew"]
    brewless.toolchain_roots == []
    operators.toolchain_owner == "jpduchesne"
    !operators.owns_toolchain?
    runners.owns_toolchain?
    brewless.owns_toolchain?
    operators.chown_command == "sudo chown -R runner:runner /home/linuxbrew/.linuxbrew /home/linuxbrew"
  end

  test "the owner of a path is read from the filesystem: this user for a directory it made, nil for one that is not there" do
    Given
    dir = Dir.mktmpdir("dev-runner-user-test-")

    Expect
    Dev::RunnerUser.owner_of(dir) == Etc.getpwuid(Process.uid).name
    Dev::RunnerUser.owner_of(File.join(dir, "missing")).nil?
    Dev::RunnerUser.new(name: "runner", home_of: ->(_user) { nil }, brew: File.join(dir, "bin", "brew"), path: "/usr/bin").toolchain_owner == Etc.getpwuid(Process.uid).name

    Cleanup
    FileUtils.rm_rf(dir)
  end

  private

  # Lambdas, not blocks: a one-parameter block is emitted as |argv,| by the
  # transform (rspockframework/ast-transform#21) and destructures an argv.
  def logs_in
    ->(argv) { argv.include?("login") }
  end

  def chowns
    ->(argv) { argv.include?("chown") }
  end

  def last_three
    ->(argv) { argv.last(3).join(" ") }
  end

  def trusts
    ->(argv) { argv.include?("trust") }
  end

  def org_tap
    Dev::TapTrust::Tap.new(user: "d3mlabs", repo: "d3mlabs")
  end

  def runner_user(homes:, gh: GhExecutor.new(logged_in: true), name: "runner", brew: nil, owner_of: ->(_path) { name }, tap: nil, ui: @ui)
    steps = Dev::PrivilegedSteps.new(executor: @executor, tty: true, purpose: "create the runner user")
    Dev::RunnerUser.new(name: name, steps: steps, executor: gh, ui: ui, home_of: ->(user) { homes[user] },
      brew: brew, path: "/opt/brew/bin:/usr/bin", owner_of: owner_of, tap: tap)
  end

  # A terminal that answers every hidden question with one secret,
  # remembering the questions.
  class SecretAnsweringUi < RecordingUi
    attr_reader :secrets_asked

    def initialize(secret)
      super()
      @secret = secret
      @secrets_asked = []
    end

    def ask_secret(question)
      @secrets_asked << question
      @secret
    end
  end
end

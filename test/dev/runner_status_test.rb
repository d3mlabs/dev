# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/agent_bootstrap"
require "dev/agent_bootstrap/darwin"
require "dev/agent_bootstrap/linux"
require "dev/runner_discovery"
require "dev/runner_registry"
require "dev/deps/dependency"
require "dev/host_reach"
require "dev/runner_status"
require "dev/runner_user"
require "dev/ui"
require "dev/wsl_keepalive_task"
require "dev/wsl_runner_host"
require "support/recording_ui"
require "etc"
require "fileutils"
require "date"
require "json"
require "stringio"
require "tmpdir"

# Probe-only executor for status inspection; records nothing mutating (status
# never mutates), answers quiet?/capture from canned tables.
class CannedStatusExecutor
  def initialize(probe_results: {}, capture_results: {})
    @probe_results = probe_results
    @capture_results = capture_results
  end

  def quiet?(*cmd)
    @probe_results.fetch(cmd, false)
  end

  def capture(*cmd)
    @capture_results.fetch(cmd, "")
  end
end unless defined?(CannedStatusExecutor)

# The GitHub-side seam for status: answers find from a responder, so tests
# canned-answer labels, absence, or a QueryError (offline).
class CannedRegistry
  attr_reader :group_asks

  PINS = Dev::LabelContracts::AI_FLOW_WORKFLOWS

  class << self
    def group(id:, name:, visibility: "selected", pinned: false)
      Dev::RunnerRegistry::Group.new(id: id, name: name, visibility: visibility, allows_public_repositories: false,
        restricted_to_workflows: pinned, selected_workflows: pinned ? PINS : [])
    end
  end

  DEFAULT_GROUP = group(id: 1, name: "Default")

  # @param group [Dev::RunnerRegistry::Group, nil] the group every runner sits
  #   in (every org runner is in one on GitHub; nil is the anomaly)
  # @param repos [Array<String>] the full names the group is visible to
  def initialize(group: DEFAULT_GROUP, repos: [], &responder)
    @responder = responder
    @group = group
    @repos = repos
    @group_asks = []
  end

  def find(scope:, name:)
    @responder ? @responder.call(scope, name) : nil
  end

  def group_of(org:, runner_id:)
    @group_asks << [org, runner_id]
    @group
  end

  def group_repositories(org:, group_id:)
    @repos.each_with_index.map { |name, i| Dev::RunnerRegistry::GroupRepository.new(id: i + 1, full_name: name) }
  end
end unless defined?(CannedRegistry)

transform!(RSpock::AST::Transformation)
class Dev::RunnerStatusTest < Minitest::Test
  include SorbetHelper

  ALL_GREEN_PROBES = {
    ["id", "-u", "ai-agent"] => true,
    ["dseditgroup", "-o", "checkmember", "-m", "human", "dev"] => true,
    ["dseditgroup", "-o", "checkmember", "-m", "ai-agent", "dev"] => true,
    ["sudo", "-n", "-u", "ai-agent", "true"] => true,
    ["brew", "list", "--formula", "colima"] => true,
  }.freeze

  # How the agent lists its own rules through the runner → agent edge.
  AGENT_SUDO_LIST = ["sudo", "-n", "-u", "ai-agent", "sudo", "-n", "-l"].freeze

  # The brew a Mac whose prefix is the human's has; the bootstrap's edge
  # is read from it (its prefix owner answered as "human" by build_status).
  HUMAN_BREW = "/opt/homebrew/bin/brew"

  # `sudo -l` as the agent, in sudo 1.9's layout (tags in its order, not ours).
  AGENT_RULES_HEADER = "User ai-agent may run the following commands on mac:\n"

  # The PATH the test's host identities run commands on.
  HOST_PATH = "/opt/brew/bin:/usr/bin"

  test "reports a host with no enrollments" do
    Given "an empty home"
    out = StringIO.new
    status = build_status(out: out)

    When "reporting"
    status.report

    Then "the report says so and no agent host section appears"
    out.string.include?("No runners enrolled on this host")
    !out.string.include?("Agent host")
  end

  # --- the WSL runner host (dev#261) ------------------------------------

  test "off WSL there is no WSL runner host frame" do
    Given
    ui = RecordingUi.new
    status = build_status(ui: ui, wsl_runner_host: nil)

    When
    status.report

    Then
    ui.rows.none? { |_kind, text, _depth| text.include?("WSL runner host") }
  end

  test "a converged WSL runner host: one frame named for the distro, every fact green" do
    Given
    ui = RecordingUi.new
    status = build_status(ui: ui, wsl_runner_host: wsl_runner_host)

    When
    status.report

    Then "the frame, then its five facts"
    frame_at = ui.rows.index([:frame, "WSL runner host (Ubuntu)", 0])
    ui.rows.slice(frame_at + 1, 5) == [
      [:note, "{{v}} systemd running (the runner service is a systemd unit)", 1],
      [:note, "{{v}} logon keepalive task 'Start-WSL-Ubuntu-Runner' registered", 1],
      [:note, "{{v}} keepalive action holds a session (conhost.exe --headless wsl.exe -d Ubuntu -u root -- sleep infinity)", 1],
      [:note, "{{v}} keepalive task running (a held session keeps Ubuntu up)", 1],
      [:note, "{{v}} Ubuntu autostarts at logon and stays up", 1],
    ]
  end

  test "a bootstrap's fire-and-forget task, not running: each shortfall is a finding with register as the remedy" do
    Given "the task cellbound-3d#280 left: wsl.exe /bin/true, the default limit, Parallel"
    out = StringIO.new
    keepalive = converged_keepalive(running: false, execute: "wsl.exe", arguments: "-d Ubuntu -u root -- /bin/true",
      execution_time_limit: "PT72H", multiple_instances: "Parallel")
    status = build_status(out: out, wsl_runner_host: wsl_runner_host(keepalive: keepalive))

    When
    status.report

    Then
    out.string.include?("✓ logon keepalive task 'Start-WSL-Ubuntu-Runner' registered")
    out.string.include?("✗ keepalive action does not hold a session (wsl.exe -d Ubuntu -u root -- /bin/true) — WSL stops Ubuntu ~20 s after it exits (run `dev runner register`)")
    out.string.include?("✗ keepalive task not running — Ubuntu stops when the last shell closes (run `dev runner register`, or `Start-ScheduledTask -TaskName 'Start-WSL-Ubuntu-Runner'`)")
    out.string.include?("✗ Ubuntu does not autostart and stay up: action does not hold a session (wsl.exe -d Ubuntu -u root -- /bin/true); execution time limit PT72H (the held session would be killed); multiple instances Parallel, not IgnoreNew (run `dev runner register`)")
  end

  test "no keepalive task: one finding, the distro does not start at logon" do
    Given
    out = StringIO.new
    status = build_status(out: out, wsl_runner_host: wsl_runner_host(keepalive: Dev::WslKeepaliveTask::Observed::ABSENT))

    When
    status.report

    Then
    out.string.include?("✗ logon keepalive task 'Start-WSL-Ubuntu-Runner' missing — Ubuntu does not start at logon (run `dev runner register`)")
    !out.string.include?("holds a session")
  end

  test "systemd is reported as running, awaiting a restart, or not enabled" do
    Given
    out = StringIO.new
    status = build_status(out: out, wsl_runner_host: wsl_runner_host(systemd_configured: configured, systemd_active: active))

    When
    status.report

    Then
    out.string.include?(line)

    Where
    configured | active | line
    true       | true   | "✓ systemd running (the runner service is a systemd unit)"
    true       | false  | "✗ systemd enabled in /etc/wsl.conf but not running — `wsl --shutdown` from Windows, then start the distro"
    false      | false  | "✗ systemd not enabled in /etc/wsl.conf — the runner service cannot be installed (run `dev runner register`)"
  end

  test "without interop (a service, an ssh login) the keepalive is unknown — neither glyph — and the line says where to ask from" do
    Given
    ui = RecordingUi.new
    status = build_status(ui: ui, wsl_runner_host: wsl_runner_host(keepalive: nil))

    When
    status.report

    Then
    ui.rows.include?([:note, "{{?}} logon keepalive 'Start-WSL-Ubuntu-Runner': cannot tell from this session (no WSL interop — a service or an ssh login) — run `dev runner status` from a shell opened in the distro on the Windows desktop", 1])
    ui.rows.none? { |_kind, text, _depth| text.include?("keepalive task") && text.include?("{{x}}") }
  end

  test "reports each discovered enrollment's scope and its GitHub labels" do
    Given "an org enrollment whose labels GitHub answers"
    out = StringIO.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs", name: "mac-box")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 42, custom_labels: %w[ai-ask ai-edit], status: "online") }
    status = build_status(out: out, home: home, registry: CannedRegistry.new(&responder))

    When "reporting"
    status.report

    Then "scope from the .runner record, labels from GitHub — nothing local"
    out.string.include?("Runner 'mac-box'")
    out.string.include?("registered: d3mlabs")
    out.string.include?("labels: ai-ask, ai-edit")
  end

  test "an org scope's slots: one header leading with the scope — count, then the runners' names — and the group (asked once, for slot 1), then each slot's own block (dev#470)" do
    Given "two slots of mac1 at the org, a custom pool in Default, which dev and plans may use"
    out = StringIO.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-ai-ask", scope: "d3mlabs", name: "mac1")
    write_runner(home, "actions-runner-ai-ask-2", scope: "d3mlabs", name: "mac1-2")
    ids = { "mac1" => 1, "mac1-2" => 2 }
    responder = ->(_scope, name) { Dev::RunnerRegistry::Runner.new(id: ids.fetch(name), custom_labels: ["ue-engine"], status: "online") }
    registry = CannedRegistry.new(repos: ["d3mlabs/dev", "d3mlabs/plans"], &responder)
    status = build_status(out: out, home: home, registry: registry)

    When "reporting"
    status.report

    Then
    out.string.include?("d3mlabs — 2 slots (2 jobs at once), runners mac1, mac1-2")
    out.string.include?("✓ group: Default\n")
    out.string.include?("✓ visible to d3mlabs/dev, d3mlabs/plans")
    out.string.include?("Runner 'mac1' (~/actions-runner-ai-ask)")
    out.string.include?("Runner 'mac1-2' (~/actions-runner-ai-ask-2)")
    registry.group_asks == [["d3mlabs", 1]]
  end

  test "the report is sections as frames and facts as notes (plans#52): a scope's slots frame holds the group facts and nests its runners' frames; a fact is a note carrying its glyph — {{v}} for ok, {{x}} for a finding — so the terminal frames it and a pipe reads it plain" do
    Given "two slots at d3mlabs, one of them gone server-side, and no org Brewfile"
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-ai-ask", scope: "d3mlabs", name: "mac1")
    write_runner(home, "actions-runner-ai-ask-2", scope: "d3mlabs", name: "mac1-2")
    responder = ->(_scope, name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["ue-engine"], status: "online") if name == "mac1" }
    status = build_status(ui: ui, home: home, registry: CannedRegistry.new(repos: ["d3mlabs/dev"], &responder))

    When "reporting"
    status.report

    Then
    ui.rows == [
      [:frame, "d3mlabs — 2 slots (2 jobs at once), runners mac1, mac1-2", 0],
      [:note, "{{v}} group: Default", 1],
      [:note, "{{v}} visible to d3mlabs/dev", 1],
      [:frame, "Runner 'mac1' (~/actions-runner-ai-ask)", 1],
      [:note, "{{v}} registered: d3mlabs", 2],
      [:note, "{{v}} labels: ue-engine", 2],
      [:frame, "Runner 'mac1-2' (~/actions-runner-ai-ask-2)", 1],
      [:note, "{{v}} registered: d3mlabs", 2],
      [:note, "{{x}} gone on GitHub — stale enrollment (re-run `dev runner register`)", 2],
      [:frame, "Host tooling", 0],
      [:note, "{{v}} no org Brewfile shipped (nothing to check)", 1],
    ]
  end

  test "a lone org enrollment still gets its slots header: the group is who may use it" do
    Given
    out = StringIO.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs", name: "mac-box")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 42, custom_labels: ["ue-engine"], status: "online") }
    everyone = CannedRegistry.group(id: 2, name: "everyone", visibility: "all")
    status = build_status(out: out, home: home, registry: CannedRegistry.new(group: everyone, &responder))

    When
    status.report

    Then
    out.string.include?("d3mlabs — 1 slot (1 job at once), runner mac-box")
    out.string.include?("✓ group: everyone\n")
    out.string.include?("✓ visible to every repo at d3mlabs")
  end

  test "ai-flow slots are held to their contract: #{expectation}" do
    Given
    out = StringIO.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-ai-ask", scope: "d3mlabs", name: "mac1")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: Dev::LabelContracts::AI_FLOW_AGENT_LABELS, status: "online") }
    status = build_status(out: out, home: home, registry: CannedRegistry.new(group: group, &responder))

    When
    status.report

    Then
    out.string.include?(expectation)

    Where
    group                                                                   | expectation
    CannedRegistry.group(id: 7, name: "ai-flow", pinned: true)              | "✓ group: ai-flow — pinned to #{Dev::LabelContracts::AI_FLOW_WORKFLOWS.join(", ")}"
    CannedRegistry.group(id: 7, name: "ai-flow", pinned: false)             | "✗ group: ai-flow drifted (not restricted to workflows) — re-run `dev runner register --org`"
    CannedRegistry.group(id: 7, name: "ai-flow", pinned: true, visibility: "all") | "✗ group: ai-flow drifted (visibility is 'all', not 'selected') — re-run `dev runner register --org`"
    CannedRegistry.group(id: 1, name: "Default", pinned: true) | "✗ group: Default — these labels belong in 'ai-flow' (re-run `dev runner register --org`)"
  end

  test "in a checkout, each org scope's slots say whether this repo may use them: #{verdict}" do
    Given
    out = StringIO.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-ai-ask", scope: "d3mlabs", name: "mac1")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["ue-engine"], status: "online") }
    registry = CannedRegistry.new(group: CannedRegistry.group(id: 1, name: "Default", visibility: visibility), repos: ["d3mlabs/Dev"], &responder)
    status = build_status(out: out, home: home, registry: registry, repo: repo)

    When
    status.report

    Then
    out.string.include?(verdict)

    Where
    visibility | repo                     | verdict
    "selected" | "d3mlabs/dev"            | "✓ d3mlabs/dev may use these slots"
    "selected" | "d3mlabs/cellbound-3d"   | "✗ d3mlabs/cellbound-3d may not use these slots — run `dev runner register --org ...` from this checkout to admit it"
    "all"      | "d3mlabs/cellbound-3d"   | "✓ d3mlabs/cellbound-3d may use these slots"
  end

  test "outside a checkout no repo verdict is given" do
    Given
    out = StringIO.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-ai-ask", scope: "d3mlabs", name: "mac1")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["ue-engine"], status: "online") }
    status = build_status(out: out, home: home, registry: CannedRegistry.new(repos: ["d3mlabs/dev"], &responder))

    When
    status.report

    Then
    !out.string.include?("may use these slots")
    !out.string.include?("may not use these slots")
  end

  test "an org runner no group lists is flagged with register as the remedy; a lone repo enrollment has no slots header at all" do
    Given
    out = StringIO.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-ai-ask", scope: "d3mlabs", name: "mac1")
    write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["x"], status: "online") }
    status = build_status(out: out, home: home, registry: CannedRegistry.new(group: nil, &responder))

    When
    status.report

    Then
    out.string.include?("✗ group: none lists 'mac1' — re-run `dev runner register --org`")
    !out.string.include?("JPDuchesne/snappy — 1 slot")
  end

  test "two repo-scoped slots get the header but no group line: a repo's runners are its own" do
    Given
    out = StringIO.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    write_runner(home, "actions-runner-snappy-2", scope: "JPDuchesne/snappy", name: "JPSFF-2")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["snappy"], status: "online") }
    registry = CannedRegistry.new(&responder)
    status = build_status(out: out, home: home, registry: registry)

    When
    status.report

    Then
    out.string.include?("JPDuchesne/snappy — 2 slots (2 jobs at once), runners JPSFF, JPSFF-2")
    !out.string.include?("group:")
    registry.group_asks == []
  end

  test "flags an enrollment GitHub has lost" do
    Given "a .runner record whose runner is gone server-side"
    out = StringIO.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs", name: "mac-box")
    status = build_status(out: out, home: home, registry: CannedRegistry.new)

    When "reporting"
    status.report

    Then
    out.string.include?("✗ gone on GitHub")
  end

  test "flags a runner GitHub lists offline while a local enrollment exists, and shows the ~-dir (#238)" do
    Given "a legacy suffixless enrollment whose registration nothing is running"
    out = StringIO.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner", scope: "JPDuchesne/snappy", name: "JPSFF")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 9, custom_labels: ["snappy"], status: "offline") }
    status = build_status(out: out, home: home, registry: CannedRegistry.new(&responder))

    When "reporting"
    status.report

    Then "the enrollment is listed by its ~-dir, its labels shown, and the offline verdict named with the remedy"
    out.string.include?("Runner 'JPSFF' (~/actions-runner)")
    out.string.include?("✓ labels: snappy")
    out.string.include?("✗ offline on GitHub — the registration is not being run (re-run `dev runner register`)")
  end

  # --- the host identity (dev#310) --------------------------------------

  test "under the host rule, every enrollment says who it runs as; one owned by someone else is drift with register as the remedy" do
    Given "an enrollment in the operator's home (owned by this test's user) and a runner user as the rule, named so it cannot be this test's own user (hosted CI runs as `runner`)"
    out = StringIO.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 9, custom_labels: ["snappy"], status: "online") }
    status = build_status(out: out, home: home, registry: CannedRegistry.new(&responder), host_identity: host_identity("svc-runner"))

    When "reporting"
    status.report

    Then
    out.string.include?("✗ runs as #{Etc.getpwuid(Process.uid).name}, not svc-runner — drift (re-run `dev runner register`)")
  end

  test "an enrollment under the runner user's home, owned by it, reads ok — and is found there" do
    Given "the enrollment where the rule puts it (this test's user plays the runner user)"
    out = StringIO.new
    me = Etc.getpwuid(Process.uid).name
    runner_home = Dir.mktmpdir
    write_runner(runner_home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 9, custom_labels: ["snappy"], status: "online") }
    status = build_status(out: out, home: Dir.mktmpdir, registry: CannedRegistry.new(&responder),
      host_identity: host_identity(me, home: runner_home))

    When "reporting"
    status.report

    Then
    out.string.include?("Runner 'JPSFF' (#{File.join(runner_home, "actions-runner-snappy")})")
    out.string.include?("✓ runs as #{me}")
  end

  test "the host identity section: the runner user exists, is logged in to GitHub as someone, and its token's expiry is read — #{what}" do
    Given
    out = StringIO.new
    headers = expires_in.nil? ? "HTTP/2.0 200 OK\n\n{}" : expiring_in(expires_in)
    executor = CannedStatusExecutor.new(
      probe_results: { ["id", "-u", "runner"] => exists, as_runner("true") => true, as_runner("gh", "auth", "status") => logged_in },
      capture_results: {
        as_runner("gh", "api", "user", "--jq", ".login") => "d3mlabs-buildhost\n",
        as_runner("gh", "api", "user", "-i") => headers,
      },
    )
    status = build_status(out: out, executor: executor, host_identity: host_identity("runner"))

    When
    status.report

    Then
    out.string.include?("Host identity (runner)")
    out.string.include?(expected)

    Where
    what                        | exists | logged_in | expires_in | expected
    "all good, token expires"   | true   | true      | 365        | "✓ gh login: d3mlabs-buildhost (token expires #{(Date.today + 365).iso8601})"
    "a token with no expiry"    | true   | true      | nil        | "✓ gh login: d3mlabs-buildhost (token does not expire)"
    "a token about to expire"   | true   | true      | 10         | "✗ gh login: d3mlabs-buildhost (token expires #{(Date.today + 10).iso8601} — within 30 days; renew it, then `sudo -iu runner gh auth login --with-token`)"
    "no gh login"               | true   | false     | nil        | "✗ no gh login — `sudo -iu runner gh auth login --with-token`"
    "no such user"              | false  | false     | nil        | "✗ user runner exists (run `dev runner register`)"
  end

  # dev#348: a sudo the operator cannot pass without a prompt used to read
  # as "no gh login" — a red line whose remedy would overwrite a working
  # login. Status never prompts; what it cannot ask as the runner user it
  # reports as unknown, with the command that can.
  test "when the operator cannot run as the runner user without a prompt, the gh login is unknown — not absent — and nothing downstream is probed" do
    Given "a runner user sudo -n refuses the operator for, and a lock to check reach over"
    out = StringIO.new
    pins = [Dev::Deps::Dependency.new(name: "ue", integration: :gh, group: "build", version: "1", hash: nil, metadata: { "repo" => "d3mlabs/unreal-engine" })]
    reach = typed_mock(Dev::HostReach)
    reach.expects(:check).never
    executor = CannedStatusExecutor.new(probe_results: { ["id", "-u", "runner"] => true, as_runner("true") => false, as_runner("gh", "auth", "status") => false })
    status = build_status(out: out, executor: executor, host_identity: host_identity("runner"), pins: pins, reach: reach)

    When
    status.report

    Then "one ? line naming who could not tell and how to find out; no ✗, no login remedy, no reach section"
    out.string.include?("? gh login: cannot tell as human (sudo as runner needs a password here) — check with `sudo -iu runner gh auth status`")
    !out.string.include?("no gh login")
    !out.string.include?("✗ ")
    !out.string.include?("Host reach")
  end

  # dev#337: jobs upgrade dev through brew, so the prefix must be the
  # runner user's; status says whose it is.
  test "the host identity section reports who owns the toolchain: the runner user, or drift with the chown" do
    Given "a logged-in runner user, and a Linuxbrew prefix owned by #{owner}"
    out = StringIO.new
    executor = CannedStatusExecutor.new(
      probe_results: { ["id", "-u", "runner"] => true, as_runner("true") => true, as_runner("gh", "auth", "status") => true },
      capture_results: { as_runner("gh", "api", "user", "--jq", ".login") => "d3mlabs-buildhost\n" },
    )
    identity = host_identity("runner", brew: "/home/linuxbrew/.linuxbrew/bin/brew", owner_of: ->(_path) { owner })
    status = build_status(out: out, executor: executor, host_identity: identity)

    When
    status.report

    Then
    out.string.include?(expected)

    Where
    owner        | expected
    "runner"     | "✓ toolchain: /home/linuxbrew/.linuxbrew owned by runner"
    "jpduchesne" | "✗ toolchain: /home/linuxbrew/.linuxbrew owned by jpduchesne, not runner — jobs cannot upgrade dev (re-run `dev runner register`)"
  end

  test "a host without brew has no toolchain line" do
    Given
    out = StringIO.new
    executor = CannedStatusExecutor.new(probe_results: { ["id", "-u", "runner"] => true })
    status = build_status(out: out, executor: executor, host_identity: host_identity("runner"))

    When
    status.report

    Then
    !out.string.include?("toolchain:")
  end

  test "with a checkout's lock, the host reach section says what the runner user can and cannot read — the grant on each miss" do
    Given "two targets, one unreachable"
    out = StringIO.new
    pins = [
      Dev::Deps::Dependency.new(name: "ue", integration: :gh, group: "build", version: "1", hash: nil, metadata: { "repo" => "d3mlabs/unreal-engine" }),
      Dev::Deps::Dependency.new(name: "x-linux", integration: :image, group: "app", version: "1", hash: nil,
        metadata: { "from" => "ghcr.io/d3mlabs/unreal-engine-build-base", "registry" => "ghcr.io/d3mlabs" }),
    ]
    reach = typed_mock(Dev::HostReach)
    target = Dev::HostReach.targets(pins).fetch(0)
    reach.stubs(:check).with(pins).returns([Dev::HostReach::Verdict.new(target: target, grant: "gh api -X PUT repos/d3mlabs/unreal-engine/collaborators/d3mlabs-buildhost -f permission=pull")])
    executor = CannedStatusExecutor.new(probe_results: { ["id", "-u", "runner"] => true, as_runner("true") => true, as_runner("gh", "auth", "status") => true },
      capture_results: { as_runner("gh", "api", "user", "--jq", ".login") => "d3mlabs-buildhost\n" })
    status = build_status(out: out, executor: executor, host_identity: host_identity("runner"), pins: pins, reach: reach)

    When
    status.report

    Then
    out.string.include?("Host reach (runner, this checkout's lock)")
    out.string.include?("✗ cannot read d3mlabs/unreal-engine — gh api -X PUT repos/d3mlabs/unreal-engine/collaborators/d3mlabs-buildhost -f permission=pull")
    out.string.include?("✓ can read package ghcr.io/d3mlabs/unreal-engine-build-base")
  end

  test "no reach section without a lock to read (projectless) or without a gh login to probe with" do
    Given
    out = StringIO.new
    pins = [Dev::Deps::Dependency.new(name: "ue", integration: :gh, group: "build", version: "1", hash: nil, metadata: { "repo" => "d3mlabs/unreal-engine" })]
    reach = typed_mock(Dev::HostReach)
    reach.expects(:check).never
    executor = CannedStatusExecutor.new(probe_results: { ["id", "-u", "runner"] => true })
    status = build_status(out: out, executor: executor, host_identity: host_identity("runner"), pins: pins, reach: reach)

    When
    status.report

    Then
    !out.string.include?("Host reach")
  end

  test "the default reach factory is HostReach over the identity" do
    Given "a status with no reach factory injected, HostReach intercepted at construction"
    out = StringIO.new
    pins = [Dev::Deps::Dependency.new(name: "ue", integration: :gh, group: "build", version: "1", hash: nil, metadata: { "repo" => "d3mlabs/unreal-engine" })]
    identity = host_identity("svc-runner")
    reach = typed_mock(Dev::HostReach)
    reach.expects(:check).once.with(pins).returns([])
    Dev::HostReach.expects(:new).once.with(identity: identity).returns(reach)
    executor = CannedStatusExecutor.new(
      probe_results: { ["id", "-u", "svc-runner"] => true, as_runner("true", user: "svc-runner") => true, as_runner("gh", "auth", "status", user: "svc-runner") => true },
      capture_results: { as_runner("gh", "api", "user", "--jq", ".login", user: "svc-runner") => "d3mlabs-buildhost\n" },
    )
    status = build_status(out: out, executor: executor, host_identity: identity, pins: pins, reach_factory: :default)

    When
    status.report

    Then
    out.string.include?("✓ can read d3mlabs/unreal-engine")
  end

  test "without a host identity (a Mac) no identity section and no runs-as line" do
    Given
    out = StringIO.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs", name: "mac-box")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 42, custom_labels: ["cellbound3d"], status: "online") }
    status = build_status(out: out, home: home, registry: CannedRegistry.new(&responder))

    When
    status.report

    Then
    !out.string.include?("Host identity")
    !out.string.include?("runs as")
  end

  test "degrades to labels-unknown when GitHub is unreachable" do
    Given "a registry that cannot be queried (offline)"
    out = StringIO.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs", name: "mac-box")
    responder = ->(_scope, _name) { raise Dev::RunnerRegistry::QueryError, "network is unreachable" }
    status = build_status(out: out, home: home, registry: CannedRegistry.new(&responder))

    When "reporting"
    status.report

    Then "the rest of the report still lands"
    out.string.include?("registered: d3mlabs")
    out.string.include?("labels unknown")
    out.string.include?("Host tooling")
  end

  test "inspects the full agent host when a discovered enrollment carries agent labels" do
    Given "an agent-labeled enrollment over an all-green host"
    out = StringIO.new
    home = Dir.mktmpdir
    runner_dir = write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs", name: "mac-box")
    work = File.join(runner_dir, "_work")
    FileUtils.mkdir_p(work)
    shared_root = Dir.mktmpdir
    executor = CannedStatusExecutor.new(
      probe_results: ALL_GREEN_PROBES,
      capture_results: {
        ["stat", "-f", "%Sg %Sp", work] => "dev drwxrwsr-x\n",
        ["stat", "-f", "%Sg %Sp", shared_root] => "dev drwxrwsr-x\n",
        ["stat", "-f", "%Sg %Sp", "/opt/homebrew/var/homebrew/locks"] => "dev drwxrwsr-x\n",
        AGENT_SUDO_LIST => "#{AGENT_RULES_HEADER}    (human) SETENV: NOPASSWD: /opt/homebrew/bin/brew\n",
      },
    )
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 42, custom_labels: ["ai-build"], status: "online") }
    status = build_status(
      out: out, home: home, registry: CannedRegistry.new(group: CannedRegistry.group(id: 7, name: "ai-flow", pinned: true), &responder),
      executor: executor, shared_root: shared_root,
      brew: HUMAN_BREW, container_required: true,
    )

    When "reporting"
    status.report

    Then "every agent host fact reads ok"
    out.string.include?("Agent host (ai-agent)")
    !out.string.include?("✗ ")
    out.string.include?("✓ agent user ai-agent exists")
    out.string.include?("✓ human in the dev group")
    out.string.include?("✓ ai-agent in the dev group")
    out.string.include?("✓ runner → agent sudoers edge (human → ai-agent, NOPASSWD:SETENV)")
    out.string.include?("✓ brew edge: ai-agent may run /opt/homebrew/bin/brew as human (NOPASSWD, SETENV)")
    out.string.include?("✓ _work tree cooperative in #{runner_dir} (group dev, setgid)")
    out.string.include?("✓ data root #{shared_root} shared with group dev (setgid)")
    out.string.include?("✓ brew lock dir /opt/homebrew/var/homebrew/locks shared with group dev (setgid, locks group-writable)")
    out.string.include?("✓ colima installed (container engine)")
  end

  # plans#59: the same facts on a Linux dev host, read with that platform's
  # probes through the Linux adapter — the runner user is dev#310's, the
  # engine fact says there is none to have.
  test "inspects a Linux agent host through the Linux adapter: the same facts, the runner user as the grantor, no engine" do
    Given "an agent-labeled enrollment on an all-green Linux host, for a repo that pins an image"
    out = StringIO.new
    home = Dir.mktmpdir
    runner_dir = write_runner(home, "actions-runner-x", scope: "d3mlabs", name: "box")
    work = File.join(runner_dir, "_work")
    FileUtils.mkdir_p(work)
    data_root = Dir.mktmpdir
    executor = CannedStatusExecutor.new(
      probe_results: { ["id", "-u", "ai-agent"] => true, ["sudo", "-n", "-u", "ai-agent", "true"] => true },
      capture_results: {
        ["id", "-nG", "runner"] => "runner docker dev\n",
        ["id", "-nG", "ai-agent"] => "ai-agent dev\n",
        ["stat", "-c", "%G %A", work] => "dev drwxrwsr-x\n",
        ["stat", "-c", "%G %A", data_root] => "dev drwxrwsr-x\n",
        ["stat", "-c", "%G %A", "/home/linuxbrew/.linuxbrew/var/homebrew/locks"] => "dev drwxrwsr-x\n",
        AGENT_SUDO_LIST => "#{AGENT_RULES_HEADER}    (runner) SETENV: NOPASSWD: /home/linuxbrew/.linuxbrew/bin/brew\n",
      },
    )
    bootstrap = Dev::AgentBootstrap::Linux.new(
      runner_user: "runner", executor: executor, out: StringIO.new, data_root: data_root, tap: nil,
      brew_executable: "/home/linuxbrew/.linuxbrew/bin/brew", owner_of: ->(_path) { "runner" },
    )
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["ai-build"], status: "online") }
    registry = CannedRegistry.new(group: CannedRegistry.group(id: 7, name: "ai-flow", pinned: true), &responder)
    status = build_status(out: out, home: home, registry: registry, executor: executor, bootstrap: bootstrap, container_required: true)

    When "reporting"
    status.report

    Then "every host fact reads ok but the engine, which names where the agent runs instead"
    out.string.include?("✓ agent user ai-agent exists")
    out.string.include?("✓ runner in the dev group")
    out.string.include?("✓ ai-agent in the dev group")
    out.string.include?("✓ runner → agent sudoers edge (runner → ai-agent, NOPASSWD:SETENV)")
    out.string.include?("✓ brew edge: ai-agent may run /home/linuxbrew/.linuxbrew/bin/brew as runner (NOPASSWD, SETENV)")
    out.string.include?("✓ _work tree cooperative in #{runner_dir} (group dev, setgid)")
    out.string.include?("✓ data root #{data_root} shared with group dev (setgid)")
    out.string.include?("✓ brew lock dir /home/linuxbrew/.linuxbrew/var/homebrew/locks shared with group dev (setgid, locks group-writable)")
    out.string.include?("✗ agent engine: ")
    out.string.include?("plans#61")
    out.string.scan("✗ ").length == 1
  end

  # dev#365: the drop-in is root-owned 0440, so the edges are read the way a
  # job exercises them — through the runner → agent edge, `-n`, list-only —
  # and matched on the facts register writes, not on the file's presence.
  test "the brew edge is read from the agent's own sudo rules — #{what}" do
    Given "an agent-labeled enrollment on a host where the agent's rules list #{what}"
    out = StringIO.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-x", scope: "d3mlabs", name: "box")
    executor = CannedStatusExecutor.new(
      probe_results: { ["sudo", "-n", "-u", "ai-agent", "true"] => true },
      capture_results: { AGENT_SUDO_LIST => rules },
    )
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["ai-build"], status: "online") }
    status = build_status(out: out, home: home, registry: CannedRegistry.new(&responder), executor: executor, brew: HUMAN_BREW)

    When "reporting"
    status.report

    Then "the runner → agent edge reads ok, and the brew edge line names the shape found"
    out.string.include?("✓ runner → agent sudoers edge (human → ai-agent, NOPASSWD:SETENV)")
    out.string.include?(expected)

    Where
    what                                    | rules                                                                         | expected
    "the edge, tags in sudo's own order"    | "#{AGENT_RULES_HEADER}    (human) SETENV: NOPASSWD: /opt/homebrew/bin/brew\n" | "✓ brew edge: ai-agent may run /opt/homebrew/bin/brew as human (NOPASSWD, SETENV)"
    "the edge without SETENV (pre-dev#361)" | "#{AGENT_RULES_HEADER}    (human) NOPASSWD: /opt/homebrew/bin/brew\n"         | "✗ brew edge without SETENV: ai-agent may run /opt/homebrew/bin/brew as human, but not as dev's escalation runs it (run `dev runner register`)"
    "another path as the owner, not brew"   | "#{AGENT_RULES_HEADER}    (human) SETENV: NOPASSWD: /usr/local/bin/brew\n"    | "✗ brew edge missing: ai-agent may run /opt/homebrew/bin/brew as human is not granted (run `dev runner register`)"
    "no rules at all (sudo -l refused)"     | ""                                                                            | "✗ brew edge missing: ai-agent may run /opt/homebrew/bin/brew as human is not granted (run `dev runner register`)"
  end

  test "a refused runner → agent probe is the finding: one red line, no prompt, and the brew edge is not read" do
    Given "an agent-labeled enrollment on a host whose drop-in grants the human nothing"
    out = StringIO.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-x", scope: "d3mlabs", name: "box")
    executor = CannedStatusExecutor.new(probe_results: { ["sudo", "-n", "-u", "ai-agent", "true"] => false })
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["ai-build"], status: "online") }
    status = build_status(out: out, home: home, registry: CannedRegistry.new(&responder), executor: executor, brew: HUMAN_BREW)

    When "reporting"
    status.report

    Then
    out.string.include?("✗ runner → agent sudoers edge missing (human → ai-agent, NOPASSWD:SETENV) — the brew edge cannot be read without it (run `dev runner register`)")
    !out.string.include?("brew edge:")
  end

  test "a host register writes no brew edge for reads ok and says why, without listing the agent's rules" do
    Given "an agent-labeled enrollment on a brewless host"
    out = StringIO.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-x", scope: "d3mlabs", name: "box")
    executor = CannedStatusExecutor.new(probe_results: { ["sudo", "-n", "-u", "ai-agent", "true"] => true })
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["ai-build"], status: "online") }
    status = build_status(out: out, home: home, registry: CannedRegistry.new(&responder), executor: executor, brew: nil)

    When "reporting"
    status.report

    Then
    out.string.include?("✓ no brew edge needed (no brew on this host)")
  end

  test "flags every missing agent host fact" do
    Given "an agent-labeled enrollment over a cold host"
    out = StringIO.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-x", scope: "d3mlabs", name: "box")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["ai-learn"], status: "online") }
    status = build_status(
      out: out, home: home, registry: CannedRegistry.new(group: CannedRegistry.group(id: 7, name: "ai-flow", pinned: true), &responder),
      shared_root: File.join(Dir.mktmpdir, "absent"),
      container_required: true,
    )

    When "reporting"
    status.report

    Then "the report carries failure markers for each fact (user, two memberships, the edge, _work, shared root, engine)"
    out.string.scan("✗ ").length == 7
  end

  test "the engine line appears only when the served repo builds in a container" do
    Given "an agent-labeled enrollment without a container"
    out = StringIO.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-x", scope: "d3mlabs", name: "box")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["ai-build"], status: "online") }
    status = build_status(out: out, home: home, registry: CannedRegistry.new(&responder), container_required: false)

    When "reporting"
    status.report

    Then
    !out.string.include?("colima")
  end

  test "host tooling reads the org Brewfile check, skipping when none is shipped" do
    Given "a Brewfile and a converged bundle"
    out = StringIO.new
    brewfile = existing_file
    executor = CannedStatusExecutor.new(
      probe_results: { ["brew", "bundle", "check", "--file=#{brewfile}"] => true },
    )
    status = build_status(out: out, executor: executor, brewfile_path: brewfile)

    # and a status with no Brewfile shipped
    out_none = StringIO.new
    status_none = build_status(out: out_none, brewfile_path: nil)

    When "reporting both"
    status.report
    status_none.report

    Then
    out.string.include?("✓ host tooling")
    out_none.string.include?("no org Brewfile")
  end

  test "the default Brewfile location sits beside the system config, when one exists" do
    Given "the machine's real settings layer"
    path = Dev::RunnerStatus.default_brewfile_path

    Expect "brewless machines get nil; deployments get the etc sibling"
    path.nil? || path.end_with?("/Brewfile")
  end

  private

  def existing_file
    path = File.join(Dir.mktmpdir, "present")
    File.write(path, "x")
    path
  end

  # A .runner record the way config.sh writes it (UTF-8 BOM + JSON).
  def write_runner(home, dir_name, scope:, name:)
    dir = File.join(home, dir_name)
    FileUtils.mkdir_p(dir)
    record = { "agentName" => name, "gitHubUrl" => "https://github.com/#{scope}" }
    File.write(File.join(dir, ".runner"), "\uFEFF#{JSON.generate(record)}")
    dir
  end

  # `gh api user -i` headers for a token expiring in `days`.
  def expiring_in(days)
    "HTTP/2.0 200 OK\nGithub-Authentication-Token-Expiration: #{(Date.today + days).iso8601} 15:00:00 UTC\n\n{}"
  end

  # The host rule's user as status sees it: a name and a home.
  def host_identity(name, home: Dir.mktmpdir, brew: nil, owner_of: ->(_path) { name })
    Dev::RunnerUser.new(name: name, home_of: ->(_user) { home }, brew: brew, path: HOST_PATH, owner_of: owner_of)
  end

  # A probe as the runner user, the way status runs them: never prompting
  # (`-n`), in the runner user's home, on the host's PATH.
  def as_runner(*cmd, user: "runner")
    ["sudo", "-n", "-u", user, "-H", "env", "-C", "/", "PATH=#{HOST_PATH}", *cmd]
  end

  # The agent host bootstrap status reads its facts through: by default a
  # Mac's, over the same canned executor, with the operator "human" as the
  # runner user, a brew (if any) whose prefix is the human's, and no tap.
  #
  # @param executor [CannedStatusExecutor] the probe seam status and the bootstrap share
  # @param shared_root [String] the Mac bootstrap's data root
  # @param brew [String, nil] the host's brew; nil for a brewless host
  # The WSL runner host as status reads it: the distro's keepalive task and
  # the facts it would re-derive (dev#261).
  def wsl_runner_host(systemd_configured: true, systemd_active: true, keepalive: converged_keepalive)
    wsl = typed_mock(Dev::WslRunnerHost)
    wsl.stubs(:task).returns(Dev::WslKeepaliveTask.new(distro: "Ubuntu"))
    wsl.stubs(:status).returns(Dev::WslRunnerHost::Status.new(
      systemd_configured: systemd_configured, systemd_active: systemd_active,
      interop: !keepalive.nil?, keepalive: keepalive,
    ))
    wsl
  end

  def converged_keepalive(**overrides)
    Dev::WslKeepaliveTask::Observed.new(**{
      present: true, running: true, execute: "conhost.exe",
      arguments: "--headless wsl.exe -d Ubuntu -u root -- sleep infinity",
      at_logon: true, execution_time_limit: "PT0S", multiple_instances: "IgnoreNew",
    }.merge(overrides))
  end

  def darwin_bootstrap(executor, shared_root:, brew:)
    Dev::AgentBootstrap::Darwin.new(
      runner_user: "human", executor: executor, out: StringIO.new, data_root: shared_root,
      home_dev: File.join(Dir.mktmpdir, "absent"), launch_agents_dir: Dir.mktmpdir,
      brew_executable: brew, owner_of: ->(_path) { "human" }, tap: nil,
    )
  end

  def build_status(out: StringIO.new, ui: Dev::NoUi.new(out: out), home: Dir.mktmpdir, registry: CannedRegistry.new,
                   executor: CannedStatusExecutor.new, shared_root: Dir.mktmpdir, brew: nil,
                   bootstrap: darwin_bootstrap(executor, shared_root: shared_root, brew: brew), brewfile_path: nil,
                   container_required: false, host_identity: nil, pins: [], repo: nil, reach: nil, reach_factory: ->(_identity) { reach },
                   wsl_runner_host: nil)
    # :default leaves RunnerStatus's own reach factory in place.
    reach_wiring = reach_factory == :default ? {} : { reach_factory: reach_factory }
    Dev::RunnerStatus.new(
      pins: pins,
      repo: repo,
      **reach_wiring,
      # The WSL runner host (dev#261): nil is any host but a WSL2 distro.
      wsl_runner_host: wsl_runner_host,
      discovery: Dev::RunnerDiscovery.new(home: home),
      registry: registry,
      ui: ui,
      executor: executor,
      operator: "human",
      host_identity: host_identity,
      bootstrap: bootstrap,
      brewfile_path: brewfile_path,
      container_required: container_required,
    )
  end
end

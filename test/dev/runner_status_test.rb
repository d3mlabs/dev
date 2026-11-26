# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/job_identity"
require "dev/job_identity/darwin"
require "dev/job_identity/linux"
require "dev/runner_discovery"
require "dev/runner_registry"
require "dev/deps/dependency"
require "dev/host_reach"
require "dev/runner_role_aliases"
require "dev/runner_status"
require "dev/runner_user"
require "dev/ui"
require "dev/version"
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
# canned-answer labels, absence, or a QueryError (offline); the group a
# runner sits in, the repos a group is visible to, and a repo's visibility
# from tables.
class CannedRegistry
  attr_reader :group_asks

  PINS = Dev::RunnerRoleAliases::WORKFLOWS_AT_MAIN

  class << self
    def group(id:, name:, visibility: "selected", pinned: false)
      Dev::RunnerRegistry::Group.new(id: id, name: name, visibility: visibility, allows_public_repositories: false,
        restricted_to_workflows: pinned, selected_workflows: pinned ? PINS : [])
    end
  end

  DEFAULT_GROUP = group(id: 1, name: "Default")
  AI_FLOW_GROUP = group(id: 7, name: "ai-flow", pinned: true)
  ORCHESTRATOR_GROUP = group(id: 8, name: "ai-orchestrator", visibility: "all", pinned: true)

  # @param group [Dev::RunnerRegistry::Group, nil] the group every runner sits
  #   in unless `groups_by_runner` says otherwise (nil is the anomaly: no
  #   group lists it)
  # @param groups_by_runner [Hash{Integer => Group}] a runner id's group
  # @param repos [Array<String>, Hash{Integer => Array<String>}] the full names a
  #   group is visible to — one list for every group, or one per group id
  # @param public_repos [Array<String>] repos GitHub records as public
  def initialize(group: DEFAULT_GROUP, groups_by_runner: {}, repos: [], public_repos: [], &responder)
    @responder = responder
    @group = group
    @groups_by_runner = groups_by_runner
    @repos = repos
    @public_repos = public_repos
    @group_asks = []
  end

  def find(scope:, name:)
    @responder ? @responder.call(scope, name) : nil
  end

  # Every runner's group at the org, as the registry reads it in one pass
  # over the groups: `groups_by_runner`'s, else `group`.
  def runner_groups(org:)
    @group_asks << [org]
    Hash.new(@group).merge(@groups_by_runner)
  end

  def group_repositories(org:, group_id:)
    names = @repos.is_a?(Hash) ? @repos.fetch(group_id, []) : @repos
    names.each_with_index.map { |name, i| Dev::RunnerRegistry::GroupRepository.new(id: i + 1, full_name: name) }
  end

  def repository(repo)
    visibility = @public_repos.any? { |name| name.casecmp?(repo) } ? "public" : "private"
    Dev::RunnerRegistry::Repository.new(id: 1, full_name: repo, visibility: visibility)
  end
end unless defined?(CannedRegistry)

transform!(RSpock::AST::Transformation)
class Dev::RunnerStatusTest < Minitest::Test
  include SorbetHelper

  # The user this test runs as: it owns every enrollment dir the test
  # writes, so it plays the runner user every slot is expected to run as.
  ME = Etc.getpwuid(Process.uid).name

  AGENT_LABELS = Dev::RunnerRoleAliases::AGENT.labels

  ALL_GREEN_PROBES = {
    ["id", "-u", "ai-agent"] => true,
    ["dseditgroup", "-o", "checkmember", "-m", ME, "dev"] => true,
    ["dseditgroup", "-o", "checkmember", "-m", "human", "dev"] => true,
    ["dseditgroup", "-o", "checkmember", "-m", "ai-agent", "dev"] => true,
    ["sudo", "-n", "-u", "ai-agent", "true"] => true,
    ["brew", "list", "--formula", "colima"] => true,
  }.freeze

  # How the agent lists its own rules through the runner → agent edge.
  AGENT_SUDO_LIST = ["sudo", "-n", "-u", "ai-agent", "sudo", "-n", "-l"].freeze

  # The brew a Mac whose prefix is the operator's has; the identity's edge
  # is read from it (its prefix owner answered as the identity's runner
  # user by build_status — "human" in the tests that read the edge).
  HUMAN_BREW = "/opt/homebrew/bin/brew"

  # `sudo -l` as the agent, in sudo 1.9's layout (tags in its order, not ours).
  AGENT_RULES_HEADER = "User ai-agent may run the following commands on mac:\n"

  # The one reason the drop-in grants the agent no brew (dev#569).
  NO_BREW_EDGE_REASON = Dev::JobIdentity::NO_BREW_EDGE.reason

  # The box's brew by realpath — the path a dev#330-era drop-in named.
  LINUXBREW_REALPATH = "/home/linuxbrew/.linuxbrew/Homebrew/bin/brew"

  # Class methods, defined ahead of the tests: Where tables are evaluated
  # in class scope as the file loads.
  class << self
    # `sudo -l` as the agent listing one rule under the header.
    def agent_rule(rule)
      "#{AGENT_RULES_HEADER}    #{rule}\n"
    end

    # The drift line status prints for a brew rule in the agent's own rules.
    def brew_edge_drift(rule)
      "✗ brew edge present — ai-agent may run brew as another user (#{rule}): #{NO_BREW_EDGE_REASON} (run `dev runner register` to retire it)"
    end
  end

  # The PATH the test's host identities run commands on.
  HOST_PATH = "/opt/brew/bin:/usr/bin"

  # The pins as the reach fact spells them.
  PINS_CLAUSE = "d3mlabs/ai-flow/ai-commands.yml@main, d3mlabs/ai-flow/origin-firing.yml@main only"

  # A reach fact's continuation lines sit under this indent.
  INDENT = " " * 9

  # A family's own line after its slot facts sits under the glyph's width.
  FACT_INDENT = "  "

  # --- the shape (plans#52): frames by subject ----------------------------

  test "a host with no enrollments: the host frame, then the note, then the posture" do
    Given
    ui = RecordingUi.new
    status = build_status(ui: ui)

    When
    status.report

    Then
    ui.rows == [
      [:frame, "mac1 · darwin · launchd", 0],
      [:note, "{{v}} no org Brewfile shipped (nothing to check)", 1],
      [:note, "No runners enrolled on this host (run `dev runner register`).", 0],
      [:note, "posture: 0 slots · 1 fact · 0 drifted", 0],
    ]
  end

  test "frames are subjects — the host, then one per role family in builtin order — and every slot fact folds into one line when the slots agree" do
    Given "an agent family of three and an orchestrator family of two at d3mlabs, every slot online, a build host at a repo"
    ui = RecordingUi.new
    home = Dir.mktmpdir
    %w[box-agent box-agent-2 box-agent-3].each_with_index { |name, i| write_runner(home, "actions-runner-agent#{"-#{i + 1}" if i > 0}", scope: "d3mlabs", name: name) }
    write_runner(home, "actions-runner-orchestrator", scope: "d3mlabs", name: "box-orchestrator")
    write_runner(home, "actions-runner-orchestrator-2", scope: "d3mlabs", name: "box-orchestrator-2")
    write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "box")
    ids = { "box-agent" => 1, "box-agent-2" => 2, "box-agent-3" => 3, "box-orchestrator" => 11, "box-orchestrator-2" => 12, "box" => 21 }
    labels = { "box-agent" => AGENT_LABELS, "box-agent-2" => AGENT_LABELS, "box-agent-3" => AGENT_LABELS,
               "box-orchestrator" => ["ai-orchestrator"], "box-orchestrator-2" => ["ai-orchestrator"], "box" => ["snappy"] }
    responder = ->(_scope, name) { Dev::RunnerRegistry::Runner.new(id: ids.fetch(name), custom_labels: labels.fetch(name), status: "online") }
    registry = CannedRegistry.new(
      groups_by_runner: { 1 => CannedRegistry::AI_FLOW_GROUP, 11 => CannedRegistry::ORCHESTRATOR_GROUP },
      repos: { 7 => ["d3mlabs/dev", "d3mlabs/plans"] }, &responder
    )
    shared_root = Dir.mktmpdir
    captures = cooperative_work_trees(home, "actions-runner-agent", "actions-runner-agent-2", "actions-runner-agent-3")
      .merge(["stat", "-f", "%Sg %Sp", shared_root] => "dev drwxrwsr-x\n")
    executor = CannedStatusExecutor.new(probe_results: ALL_GREEN_PROBES, capture_results: captures)
    status = build_status(ui: ui, home: home, registry: registry, executor: executor, shared_root: shared_root, host: "box", host_os: "linux")

    When
    status.report

    Then "the family frames are siblings of the host frame, each with its reach and one folded slot line"
    rows_from(ui, "agent · 3 slots · d3mlabs") == [
      [:frame, "agent · 3 slots · d3mlabs", 0],
      [:note, "{{v}} reach: jobs from d3mlabs/dev, d3mlabs/plans", 1],
      [:note, "#{INDENT}via #{PINS_CLAUSE}", 1],
      [:note, "#{INDENT}runs-on ai-ask | ai-edit | ai-split | ai-build | ai-learn", 1],
      [:note, "{{v}} box-agent, -2, -3 — online · service installed · runs as #{ME} · _work shared with group dev", 1],
      [:frame, "orchestrator · 2 slots · d3mlabs", 0],
      [:note, "{{v}} reach: jobs from every d3mlabs repo", 1],
      [:note, "#{INDENT}via #{PINS_CLAUSE}", 1],
      [:note, "#{INDENT}runs-on ai-orchestrator", 1],
      [:note, "{{v}} box-orchestrator, -2 — online · service installed · runs as #{ME}", 1],
      [:frame, "build-host · 1 slot · JPDuchesne/snappy", 0],
      [:note, "{{v}} reach: jobs from JPDuchesne/snappy", 1],
      [:note, "#{INDENT}via any workflow", 1],
      [:note, "#{INDENT}runs-on snappy", 1],
      [:note, "{{v}} box — online · service installed · runs as #{ME}", 1],
      [:note, "posture: 6 slots · 13 facts · 0 drifted", 0],
    ]

    # the host frame is first, and the org's groups were read once, for every slot
    ui.rows.fetch(0) == [:frame, "box · linux · systemd", 0]
    registry.group_asks == [["d3mlabs"]]
  end

  # `.runner` records the group config.sh registered into; `dev runner
  # register` moves a slot between groups through the API afterwards
  # (RunnerGroups#place!) and the record keeps the old name. The box's
  # ten orchestrator slots read as a thirteen-slot agent family held
  # against the agent's labels (plans#79 step 4, 2026-11-26).
  test "a slot whose record names the group it was registered into is filed under the group GitHub has it in now" do
    Given "an orchestrator slot whose record says ai-flow, sitting in ai-orchestrator on GitHub, beside an agent slot"
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-agent", scope: "d3mlabs", name: "box-agent", pool: "ai-flow")
    write_runner(home, "actions-runner-orchestrator", scope: "d3mlabs", name: "box-orchestrator", pool: "ai-flow")
    ids = { "box-agent" => 1, "box-orchestrator" => 11 }
    labels = { "box-agent" => AGENT_LABELS, "box-orchestrator" => ["ai-orchestrator"] }
    responder = ->(_scope, name) { Dev::RunnerRegistry::Runner.new(id: ids.fetch(name), custom_labels: labels.fetch(name), status: "online") }
    registry = CannedRegistry.new(
      groups_by_runner: { 1 => CannedRegistry::AI_FLOW_GROUP, 11 => CannedRegistry::ORCHESTRATOR_GROUP },
      repos: { 7 => ["d3mlabs/dev"] }, &responder
    )
    executor = CannedStatusExecutor.new(probe_results: ALL_GREEN_PROBES, capture_results: cooperative_work_trees(home, "actions-runner-agent"))
    status = build_status(ui: ui, home: home, registry: registry, executor: executor, host: "box", host_os: "linux")

    When
    status.report

    Then "two families of one slot each, the orchestrator's green against its own role"
    ui.rows.select { |kind, _text, _depth| kind == :frame }.map { |_kind, text, _depth| text }.drop(1) ==
      ["agent · 1 slot · d3mlabs", "orchestrator · 1 slot · d3mlabs"]
    rows_from(ui, "orchestrator · 1 slot · d3mlabs").take(5) == [
      [:frame, "orchestrator · 1 slot · d3mlabs", 0],
      [:note, "{{v}} reach: jobs from every d3mlabs repo", 1],
      [:note, "#{INDENT}via #{PINS_CLAUSE}", 1],
      [:note, "#{INDENT}runs-on ai-orchestrator", 1],
      [:note, "{{v}} box-orchestrator — online · service installed · runs as #{ME}", 1],
    ]
  end

  test "a deviating slot breaks out of the fold as its own ✗ line, its dir beside its name — #{what}" do
    Given "three orchestrator slots, the second #{what}"
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-orchestrator", scope: "d3mlabs", name: "box-orchestrator")
    write_runner(home, "actions-runner-orchestrator-2", scope: "d3mlabs", name: "box-orchestrator-2", service: service)
    write_runner(home, "actions-runner-orchestrator-3", scope: "d3mlabs", name: "box-orchestrator-3")
    responder = lambda do |_scope, name|
      next nil if name == "box-orchestrator-2" && status_word.nil?

      Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: name == "box-orchestrator-2" ? labels : ["ai-orchestrator"], status: name == "box-orchestrator-2" ? status_word : "online")
    end
    status = build_status(ui: ui, home: home, registry: CannedRegistry.new(group: CannedRegistry::ORCHESTRATOR_GROUP, &responder))

    When
    status.report

    Then "the two agreeing slots fold; the deviant names its findings and the remedy"
    ui.rows.include?([:note, "{{v}} box-orchestrator, -3 — online · service installed · runs as #{ME}", 1])
    ui.rows.include?([:note, "{{x}} box-orchestrator-2 (~/actions-runner-orchestrator-2) — #{finding} (re-run `dev runner register` to repair, or `dev runner unregister ~/actions-runner-orchestrator-2` to retire it)", 1])

    Where
    what                        | status_word | labels                     | service | finding
    "offline on GitHub"         | "offline"   | ["ai-orchestrator"]        | true    | "offline on GitHub — the registration is not being run"
    "gone on GitHub"            | nil         | ["ai-orchestrator"]        | true    | "gone on GitHub — stale enrollment"
    "carrying another label"    | "online"    | ["ai-orchestrator", "gpu"] | true    | "labels ai-orchestrator | gpu, not the role's ai-orchestrator"
    "without its service"       | "online"    | ["ai-orchestrator"]        | false   | "no service installed"
    "offline and serviceless"   | "offline"   | ["ai-orchestrator"]        | false   | "offline on GitHub — the registration is not being run; no service installed"
  end

  test "red slots that agree fold into one line naming each dir's unregister; a family whose every slot is red adds the scope's (dev#623)" do
    Given "two orchestrator slots, both offline on GitHub"
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-orchestrator", scope: "d3mlabs", name: "box-orchestrator")
    write_runner(home, "actions-runner-orchestrator-2", scope: "d3mlabs", name: "box-orchestrator-2")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["ai-orchestrator"], status: "offline") }
    status = build_status(ui: ui, home: home, registry: CannedRegistry.new(group: CannedRegistry::ORCHESTRATOR_GROUP, &responder))

    When
    status.report

    Then "one folded ✗ line, each slot's dir in the remedy, then the family's retire line — not a fact of its own"
    rows_from(ui, "orchestrator · 2 slots · d3mlabs").drop(4).take(2) == [
      [:note, "{{x}} box-orchestrator (~/actions-runner-orchestrator), box-orchestrator-2 (~/actions-runner-orchestrator-2) — offline on GitHub — the registration is not being run " \
              "(re-run `dev runner register` to repair, or `dev runner unregister ~/actions-runner-orchestrator`, `dev runner unregister ~/actions-runner-orchestrator-2` to retire them)", 1],
      [:note, "#{FACT_INDENT}every slot red — `dev runner unregister d3mlabs` retires the family", 1],
    ]
    ui.rows.last == [:note, "posture: 2 slots · 3 facts · 1 drifted", 0]
  end

  test "a family whose slots GitHub could not be asked about is not red: no retire line" do
    Given "one slot, GitHub unreachable"
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-orchestrator", scope: "d3mlabs", name: "box-orchestrator")
    responder = ->(_scope, _name) { raise Dev::RunnerRegistry::QueryError, "network is unreachable" }
    status = build_status(ui: ui, home: home, registry: CannedRegistry.new(&responder))

    When
    status.report

    Then
    ui.rows.none? { |_kind, text, _depth| text.include?("retires the family") }
  end

  test "a run of consecutive slot suffixes collapses to its ends" do
    Given "four orchestrator slots"
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-orchestrator", scope: "d3mlabs", name: "box-orchestrator")
    (2..4).each { |n| write_runner(home, "actions-runner-orchestrator-#{n}", scope: "d3mlabs", name: "box-orchestrator-#{n}") }
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["ai-orchestrator"], status: "online") }
    status = build_status(ui: ui, home: home, registry: CannedRegistry.new(group: CannedRegistry::ORCHESTRATOR_GROUP, &responder))

    When
    status.report

    Then
    ui.rows.include?([:frame, "orchestrator · 4 slots · d3mlabs", 0])
    ui.rows.include?([:note, "{{v}} box-orchestrator, -2 … -4 — online · service installed · runs as #{ME}", 1])
  end

  test "under the host rule a slot owned by anyone but the runner user is drift, named with register as the remedy" do
    Given "an enrollment in the operator's home (owned by this test's user) and a runner user named so it cannot be this test's own user"
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 9, custom_labels: ["snappy"], status: "online") }
    status = build_status(ui: ui, home: home, registry: CannedRegistry.new(&responder), host_identity: host_identity("svc-runner"))

    When
    status.report

    Then
    ui.rows.include?([:note, "{{x}} JPSFF (~/actions-runner-snappy) — runs as #{ME}, not svc-runner (re-run `dev runner register` to repair, or `dev runner unregister ~/actions-runner-snappy` to retire it)", 1])
  end

  test "an enrollment under the runner user's home, owned by it, is found there and reads ok" do
    Given "the enrollment where the rule puts it (this test's user plays the runner user)"
    ui = RecordingUi.new
    runner_home = Dir.mktmpdir
    write_runner(runner_home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 9, custom_labels: ["snappy"], status: "online") }
    status = build_status(ui: ui, home: Dir.mktmpdir, registry: CannedRegistry.new(&responder), host_identity: host_identity(ME, home: runner_home))

    When
    status.report

    Then
    ui.rows.include?([:note, "{{v}} JPSFF — online · service installed · runs as #{ME}", 1])
  end

  # --- reach: one fact, three clauses, the mechanism as evidence ----------

  test "an agent family without the pin: the via clause names what the role expects, and the group is the evidence under the ✗" do
    Given
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-agent", scope: "d3mlabs", name: "box-agent")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: AGENT_LABELS, status: "online") }
    registry = CannedRegistry.new(group: CannedRegistry.group(id: 7, name: "ai-flow", pinned: false), repos: ["d3mlabs/dev"], &responder)
    status = build_status(ui: ui, home: home, registry: registry, executor: CannedStatusExecutor.new(capture_results: cooperative_work_trees(home, "actions-runner-agent")))

    When
    status.report

    Then
    rows_from(ui, "agent · 1 slot · d3mlabs").take(5) == [
      [:frame, "agent · 1 slot · d3mlabs", 0],
      [:note, "{{x}} reach: jobs from d3mlabs/dev", 1],
      [:note, "#{INDENT}via any workflow — the agent role expects #{PINS_CLAUSE}", 1],
      [:note, "#{INDENT}runs-on ai-ask | ai-edit | ai-split | ai-build | ai-learn", 1],
      [:note, "#{INDENT}cause: slots sit in org group `ai-flow` (visibility selected, not restricted to workflows) — re-run `dev runner register --org --role agent` from the checkout whose dev.yml declares agent", 1],
    ]
  end

  # dev#657: a role is its project's declaration, so away from the
  # declaring checkout (and past the aliases) a slot is known by its pool
  # alone — its reach read, not judged.
  test "a family of a role no declaration at hand names is known by its pool: the reach is a ? fact with the clauses as GitHub has them" do
    Given "a slot in a pinned group `ue-farm`, status run with no declaration of such a role"
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-ue-farm", scope: "d3mlabs", name: "box-ue-farm", pool: "ue-farm")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: %w[ue gpu], status: "online") }
    group = Dev::RunnerRegistry::Group.new(id: 9, name: "ue-farm", visibility: "selected", allows_public_repositories: false,
      restricted_to_workflows: true, selected_workflows: ["d3mlabs/cellbound-3d/.github/workflows/build.yml@refs/tags/v3"])
    registry = CannedRegistry.new(group: group, repos: ["d3mlabs/cellbound-3d"], &responder)
    status = build_status(ui: ui, home: home, registry: registry, roles: {})

    When
    status.report

    Then "the frame is named for the pool; the reach is unknown, pointing at the declaring checkout; the slot facts are the slot's"
    rows_from(ui, "ue-farm · 1 slot · d3mlabs") == [
      [:frame, "ue-farm · 1 slot · d3mlabs", 0],
      [:note, "{{?}} reach: jobs from d3mlabs/cellbound-3d — unverified: no declaration of a role in group `ue-farm` at hand " \
              "(run `dev runner status` from the checkout whose dev.yml declares it)", 1],
      [:note, "#{INDENT}via d3mlabs/cellbound-3d/build.yml@v3 only", 1],
      [:note, "#{INDENT}runs-on ue | gpu", 1],
      [:note, "{{v}} box-ue-farm — online · service installed · runs as #{ME}", 1],
      [:note, "posture: 1 slot · 3 facts · 0 drifted", 0],
    ]
  end

  test "the same family from the declaring checkout is held against its declaration, pins at the project's series and all" do
    Given "the ue-farm role as cellbound-3d's dev.yml declares it, bound to the repo at v3"
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-ue-farm", scope: "d3mlabs", name: "box-ue-farm", pool: "ue-farm")
    declaration = Dev::RunnerRole::Declaration.new(
      name: "ue-farm", labels: %w[ue gpu], group: "ue-farm", workflows: [".github/workflows/build.yml"], job_identity: "ue-builder",
    )
    role = declaration.bind(repo: "d3mlabs/cellbound-3d", version: "3.1.0")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: %w[ue gpu], status: "online") }
    group = Dev::RunnerRegistry::Group.new(id: 9, name: "ue-farm", visibility: "selected", allows_public_repositories: false,
      restricted_to_workflows: true, selected_workflows: ["d3mlabs/cellbound-3d/.github/workflows/build.yml@refs/tags/v3"])
    registry = CannedRegistry.new(group: group, repos: ["d3mlabs/cellbound-3d"], &responder)
    shared_root = Dir.mktmpdir
    executor = CannedStatusExecutor.new(
      probe_results: { ["id", "-u", "ue-builder"] => true, ["sudo", "-n", "-u", "ue-builder", "true"] => false },
      capture_results: cooperative_work_trees(home, "actions-runner-ue-farm"),
    )
    status = build_status(ui: ui, home: home, registry: registry, roles: { "ue-farm" => role }, executor: executor, shared_root: shared_root)

    When
    status.report

    Then "the reach reads ok against the declaration, and the host frame carries the declared job identity's facts"
    rows_from(ui, "ue-farm · 1 slot · d3mlabs").take(5) == [
      [:frame, "ue-farm · 1 slot · d3mlabs", 0],
      [:note, "{{v}} reach: jobs from d3mlabs/cellbound-3d", 1],
      [:note, "#{INDENT}via d3mlabs/cellbound-3d/build.yml@v3 only", 1],
      [:note, "#{INDENT}runs-on ue | gpu", 1],
      [:note, "{{v}} box-ue-farm — online · service installed · runs as #{ME} · _work shared with group dev", 1],
    ]
    ui.rows.include?([:note, "{{v}} job identity ue-builder exists", 1])
    ui.rows.include?([:note, "{{x}} runner → ue-builder sudoers edge missing (#{ME} → ue-builder, NOPASSWD:SETENV) — ue-builder's rules cannot be read without it (run `dev runner register`)", 1])
    ui.rows.none? { |_kind, text, _depth| text.include?("job identity ai-agent") }
  end

  # --- a lane in a role referenced from another project (dev#701) ------------

  # ai-flow's agent role as cellbound-3d's reference reads it: labels and
  # job identity at repo scope — the shape of the repo's own lane.
  REFERENCED_AGENT = Dev::RunnerRole::Declaration.new(
    name: "agent", labels: AGENT_LABELS, group: "ai-flow", workflows: [".github/workflows/ai-commands.yml"], job_identity: "ai-agent",
  ).as_referenced

  test "a repo-scoped slot of a referenced role is reported under that role, held against the referenced shape, with its job identity's facts" do
    Given "cellbound-3d's agent lane on this host, status run from the referencing checkout"
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-agent", scope: "d3mlabs/cellbound-3d", name: "box-agent")
    registry = CannedRegistry.new(repos: ["d3mlabs/cellbound-3d"]) { |_scope, _name| Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: AGENT_LABELS, status: "online") }
    executor = CannedStatusExecutor.new(probe_results: { ["id", "-u", "ai-agent"] => true }, capture_results: cooperative_work_trees(home, "actions-runner-agent"))
    status = build_status(ui: ui, home: home, registry: registry, roles: { "agent" => REFERENCED_AGENT }, executor: executor, repo: "d3mlabs/cellbound-3d")

    When
    status.report

    Then "the frame is the role's at the repo; the reach is the repo registration's, ok; the identity's facts are in the host frame"
    rows_from(ui, "agent · 1 slot · d3mlabs/cellbound-3d").take(5) == [
      [:frame, "agent · 1 slot · d3mlabs/cellbound-3d", 0],
      [:note, "{{v}} reach: jobs from {{bold:d3mlabs/cellbound-3d}}", 1],
      [:note, "#{INDENT}via any workflow", 1],
      [:note, "#{INDENT}runs-on #{AGENT_LABELS.join(" | ")}", 1],
      [:note, "{{v}} box-agent — online · service installed · runs as #{ME} · _work shared with group dev", 1],
    ]
    ui.rows.include?([:note, "{{v}} job identity ai-agent exists", 1])
  end

  test "a referenced lane whose labels drifted names the referencing checkout as where to re-register: the lane is that repo's" do
    Given "the slot advertising one agent label short"
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-agent", scope: "d3mlabs/cellbound-3d", name: "box-agent")
    stale = AGENT_LABELS.take(AGENT_LABELS.length - 1)
    registry = CannedRegistry.new(repos: ["d3mlabs/cellbound-3d"]) { |_scope, _name| Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: stale, status: "online") }
    status = build_status(ui: ui, home: home, registry: registry, roles: { "agent" => REFERENCED_AGENT }, repo: "d3mlabs/cellbound-3d")

    When
    status.report

    Then
    ui.rows.any? { |_kind, text, _depth| text.include?("re-run `dev runner register --role agent` from the checkout whose dev.yml references agent") }
    ui.rows.none? { |_kind, text, _depth| text.include?("whose dev.yml declares agent") }
  end

  # --- the job-started hook dev 0.9.x left (dev#700) -------------------------

  test "a slot still carrying the retired job-started hook is a finding — the hook's keys in .env or its script — #{what}" do
    Given "two orchestrator slots, the second from dev 0.9.x"
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-orchestrator", scope: "d3mlabs", name: "box-orchestrator")
    stale = write_runner(home, "actions-runner-orchestrator-2", scope: "d3mlabs", name: "box-orchestrator-2", env: env)
    File.write(File.join(stale, "dev-job-started.sh"), "#!/usr/bin/env bash\n") if script
    registry = CannedRegistry.new(group: CannedRegistry::ORCHESTRATOR_GROUP) { |_scope, _name| Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["ai-orchestrator"], status: "online") }
    status = build_status(ui: ui, home: home, registry: registry)

    When
    status.report

    Then "the clean slot holds; the stale one names the hook, with register as the remedy"
    ui.rows.include?([:note, "{{v}} box-orchestrator — online · service installed · runs as #{ME}", 1])
    ui.rows.include?([:note, "{{x}} box-orchestrator-2 (~/actions-runner-orchestrator-2) — job-started hook left from dev 0.9.x (dev-job-started.sh) — " \
                             "jobs run the checkout's lock, not a head (re-run `dev runner register` to repair, or `dev runner unregister ~/actions-runner-orchestrator-2` to retire it)", 1])

    Where
    what               | env | script
    "both keys"        | "GH_TOKEN=x\nACTIONS_RUNNER_HOOK_JOB_STARTED=/x/dev-job-started.sh\nDEV_STREAM=d3mlabs/ai-flow@gh ~> 1\n" | false
    "the script alone" | "GH_TOKEN=x\n" | true
  end

  test "a slot whose .env holds only the runner's own lines is not a hook finding" do
    Given
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-orchestrator", scope: "d3mlabs", name: "box-orchestrator", env: "LANG=C\nGH_TOKEN=x\n")
    registry = CannedRegistry.new(group: CannedRegistry::ORCHESTRATOR_GROUP) { |_scope, _name| Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["ai-orchestrator"], status: "online") }
    status = build_status(ui: ui, home: home, registry: registry)

    When
    status.report

    Then
    ui.rows.include?([:note, "{{v}} box-orchestrator — online · service installed · runs as #{ME}", 1])
  end

  # --- the jobs' gh credential on the Mac rule (JobGhToken) -----------------

  test "on the Mac rule a slot whose .env carries no GH_TOKEN is a finding: its jobs cannot read the keychain login — #{what}" do
    Given "two slots, the second without the jobs' credential"
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-orchestrator", scope: "d3mlabs", name: "box-orchestrator")
    write_runner(home, "actions-runner-orchestrator-2", scope: "d3mlabs", name: "box-orchestrator-2", env: env)
    registry = CannedRegistry.new(group: CannedRegistry::ORCHESTRATOR_GROUP) { |_scope, _name| Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["ai-orchestrator"], status: "online") }
    status = build_status(ui: ui, home: home, registry: registry)

    When
    status.report

    Then "the carrying slot holds; the bare one names the credential, with register as the remedy"
    ui.rows.include?([:note, "{{v}} box-orchestrator — online · service installed · runs as #{ME}", 1])
    ui.rows.include?([:note, "{{x}} box-orchestrator-2 (~/actions-runner-orchestrator-2) — jobs have no gh credential (no GH_TOKEN in .env; " \
                             "the keychain login is unreadable from the service) (re-run `dev runner register` to repair, or `dev runner unregister ~/actions-runner-orchestrator-2` to retire it)", 1])

    Where
    what                     | env
    "the runner's own lines" | "LANG=C\n"
    "no .env"                | nil
  end

  test "on the Linux rule the runner user's login is the credential: a slot without GH_TOKEN in .env is not a finding" do
    Given "a Linux host whose runner user owns the slot, its .env the runner's own"
    ui = RecordingUi.new
    runner_home = Dir.mktmpdir
    write_runner(runner_home, "actions-runner-orchestrator", scope: "d3mlabs", name: "box-orchestrator", env: "LANG=C\n")
    registry = CannedRegistry.new(group: CannedRegistry::ORCHESTRATOR_GROUP) { |_scope, _name| Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["ai-orchestrator"], status: "online") }
    status = build_status(ui: ui, home: Dir.mktmpdir, registry: registry, host_identity: host_identity(ME, home: runner_home), host_os: "linux")

    When
    status.report

    Then
    ui.rows.none? { |_kind, text, _depth| text.include?("no gh credential") }
  end

  test "an agent family's group drifted to every repo: the from clause names the expected shape" do
    Given
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-agent", scope: "d3mlabs", name: "box-agent")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: AGENT_LABELS, status: "online") }
    registry = CannedRegistry.new(group: CannedRegistry.group(id: 7, name: "ai-flow", visibility: "all", pinned: true), &responder)
    status = build_status(ui: ui, home: home, registry: registry)

    When
    status.report

    Then
    ui.rows.include?([:note, "{{x}} reach: jobs from every d3mlabs repo — the agent role expects a selection", 1])
    ui.rows.include?([:note, "#{INDENT}cause: slots sit in org group `ai-flow` (visibility all, restricted to 2 workflows) — re-run `dev runner register --org --role agent` from the checkout whose dev.yml declares agent", 1])
  end

  test "a build host found in an org group that pins workflows (dev#471): the via clause drifts and the group is named as the cause" do
    Given "an org pool of one custom label sitting in Default, which the console pinned"
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-ue-engine", scope: "d3mlabs", name: "mac1")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["ue-engine"], status: "online") }
    registry = CannedRegistry.new(group: CannedRegistry.group(id: 1, name: "Default", pinned: true), repos: ["d3mlabs/cellbound-3d"], &responder)
    status = build_status(ui: ui, home: home, registry: registry)

    When
    status.report

    Then
    rows_from(ui, "build-host · 1 slot · d3mlabs").take(5) == [
      [:frame, "build-host · 1 slot · d3mlabs", 0],
      [:note, "{{x}} reach: jobs from d3mlabs/cellbound-3d", 1],
      [:note, "#{INDENT}via #{PINS_CLAUSE} — the build-host role expects any workflow", 1],
      [:note, "#{INDENT}runs-on ue-engine", 1],
      [:note, "#{INDENT}cause: slots sit in org group `Default` (visibility selected, restricted to 2 workflows) — re-run `dev runner register` from the repo's checkout", 1],
    ]
  end

  test "a build host in a human's unpinned org group reaches its selection through any workflow: no drift, no mechanism named" do
    Given
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-ue-engine", scope: "d3mlabs", name: "mac1")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["ue-engine"], status: "online") }
    registry = CannedRegistry.new(group: CannedRegistry.group(id: 2, name: "ue-hosted"), repos: ["d3mlabs/cellbound-3d", "d3mlabs/unreal-engine"], &responder)
    status = build_status(ui: ui, home: home, registry: registry)

    When
    status.report

    Then
    ui.rows.include?([:note, "{{v}} reach: jobs from d3mlabs/cellbound-3d, d3mlabs/unreal-engine", 1])
    ui.rows.none? { |_kind, text, _depth| text.include?("ue-hosted") }
  end

  test "a build host for a public repo: the role refuses, and the ✗ says the repo is exposed" do
    Given
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-dev", scope: "d3mlabs/dev", name: "mac1")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["dev"], status: "online") }
    status = build_status(ui: ui, home: home, registry: CannedRegistry.new(public_repos: ["d3mlabs/dev"], &responder))

    When
    status.report

    Then
    rows_from(ui, "build-host · 1 slot · d3mlabs/dev").take(5) == [
      [:frame, "build-host · 1 slot · d3mlabs/dev", 0],
      [:note, "{{x}} reach: jobs from d3mlabs/dev", 1],
      [:note, "#{INDENT}via any workflow", 1],
      [:note, "#{INDENT}runs-on dev", 1],
      [:note, "#{INDENT}exposed: d3mlabs/dev is public and its build-host runners would take jobs from any of its workflows — an approved fork PR's YAML could land on this host. Enroll for a private repo, or put the runners in a group pinned to the workflows that may use them (https://github.com/d3mlabs/dev/blob/main/docs/runners.md#scope).", 1],
    ]

    # the mechanism is evidence under the ✗ too; the exposure carries its own advice, so no remedy follows it
    ui.rows.include?([:note, "#{INDENT}cause: reach is fixed by the repo registration at d3mlabs/dev (its own workflows, no pin) — only an org registration in a group can widen or pin it", 1])
  end

  test "an agent family registered at a private repo (cellbound-3d's Mac slot): its reach is that repo through any workflow, and that is the role's expectation at repo scope — ✓" do
    Given
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs/cellbound-3d", name: "mac-agent")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: AGENT_LABELS, status: "online") }
    registry = CannedRegistry.new(&responder)
    status = build_status(ui: ui, home: home, registry: registry, executor: CannedStatusExecutor.new(capture_results: cooperative_work_trees(home, "actions-runner-cellbound3d")))

    When
    status.report

    Then
    rows_from(ui, "agent · 1 slot · d3mlabs/cellbound-3d").take(4) == [
      [:frame, "agent · 1 slot · d3mlabs/cellbound-3d", 0],
      [:note, "{{v}} reach: jobs from d3mlabs/cellbound-3d", 1],
      [:note, "#{INDENT}via any workflow", 1],
      [:note, "#{INDENT}runs-on ai-ask | ai-edit | ai-split | ai-build | ai-learn", 1],
    ]
    ui.rows.none? { |_kind, text, _depth| text.include?("cause:") }
    registry.group_asks.empty?
  end

  test "every family frame names its scope — the argument `dev runner unregister` takes — so two families of one role are told apart without reading the from clause (dev#623)" do
    Given "the Mac today: three org agent slots and cellbound-3d's repo-scoped agent slot"
    ui = RecordingUi.new
    home = Dir.mktmpdir
    %w[mac-agent mac-agent-2 mac-agent-3].each_with_index { |name, i| write_runner(home, "actions-runner-agent#{"-#{i + 1}" if i > 0}", scope: "d3mlabs", name: name) }
    write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs/cellbound-3d", name: "mac")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: AGENT_LABELS, status: "online") }
    registry = CannedRegistry.new(group: CannedRegistry::AI_FLOW_GROUP, repos: ["d3mlabs/dev"], &responder)
    captures = cooperative_work_trees(home, "actions-runner-agent", "actions-runner-agent-2", "actions-runner-agent-3", "actions-runner-cellbound3d")
    status = build_status(ui: ui, home: home, registry: registry, executor: CannedStatusExecutor.new(capture_results: captures))

    When
    status.report

    Then
    ui.rows.select { |kind, _text, _depth| kind == :frame }.map { |_kind, text, _depth| text }.drop(1) ==
      ["agent · 3 slots · d3mlabs", "agent · 1 slot · d3mlabs/cellbound-3d"]
  end

  test "with the runner found but its group unqueryable, the reach is unknown — neither glyph — and the slot line still lands" do
    Given "a registry that lists the runner and then fails on the group lookup"
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-agent", scope: "d3mlabs", name: "box-agent")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: AGENT_LABELS, status: "online") }
    registry = CannedRegistry.new(&responder)
    registry.define_singleton_method(:runner_groups) { |org:| raise Dev::RunnerRegistry::QueryError, "HTTP 502 from api.github.com" }
    status = build_status(ui: ui, home: home, registry: registry, executor: CannedStatusExecutor.new(capture_results: cooperative_work_trees(home, "actions-runner-agent")))

    When
    status.report

    Then
    rows_from(ui, "agent · 1 slot · d3mlabs").take(3) == [
      [:frame, "agent · 1 slot · d3mlabs", 0],
      [:note, "{{?}} reach: cannot tell — HTTP 502 from api.github.com", 1],
      [:note, "{{v}} box-agent — online · service installed · runs as #{ME} · _work shared with group dev", 1],
    ]
    rows_from(ui, "agent · 1 slot · d3mlabs").none? { |_kind, text, _depth| text.include?("{{x}}") }
  end

  test "an org slot no group lists has no reach: a ✗ with register as the remedy" do
    Given
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-x", scope: "d3mlabs", name: "mac1")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["x"], status: "online") }
    status = build_status(ui: ui, home: home, registry: CannedRegistry.new(group: nil, &responder))

    When
    status.report

    Then
    ui.rows.include?([:note, "{{x}} reach: none — no org group at d3mlabs lists mac1 (re-run `dev runner register` from the repo's checkout)", 1])
  end

  # dev#657: a slot whose record names a pool no org group lists any more
  # (the group deleted under it) is known by its pool alone, so the only
  # checkout that can converge it is the one declaring a role in that group.
  test "a pooled-role slot no org group lists has no reach: the remedy names the declaring checkout by the pool" do
    Given "a slot recorded in pool `ue-farm`, no declaration at hand, GitHub listing it in no group"
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-ue-farm", scope: "d3mlabs", name: "box-ue-farm", pool: "ue-farm")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: %w[ue gpu], status: "online") }
    status = build_status(ui: ui, home: home, registry: CannedRegistry.new(group: nil, &responder), roles: {})

    When
    status.report

    Then
    ui.rows.include?([:note, "{{x}} reach: none — no org group at d3mlabs lists box-ue-farm (re-run `dev runner register --org --role <role>` " \
                             "from the checkout whose dev.yml declares the role in group `ue-farm`)", 1])
  end

  test "a family GitHub has lost entirely: its role from the pool, no reach, each slot a stale enrollment" do
    Given
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-agent", scope: "d3mlabs", name: "box-agent", pool: "ai-flow")
    executor = CannedStatusExecutor.new(capture_results: cooperative_work_trees(home, "actions-runner-agent"))
    status = build_status(ui: ui, home: home, registry: CannedRegistry.new, executor: executor)

    When
    status.report

    Then
    rows_from(ui, "agent · 1 slot · d3mlabs").take(4) == [
      [:frame, "agent · 1 slot · d3mlabs", 0],
      [:note, "{{x}} reach: none — GitHub lists no slot of this family (stale enrollments; re-run `dev runner register`)", 1],
      [:note, "{{x}} box-agent (~/actions-runner-agent) — gone on GitHub — stale enrollment (re-run `dev runner register` to repair, or `dev runner unregister ~/actions-runner-agent` to retire it)", 1],
      [:note, "#{FACT_INDENT}every slot red — `dev runner unregister d3mlabs` retires the family", 1],
    ]
  end

  test "with GitHub unreachable every GitHub-side fact is unknown — neither glyph — and the host's own facts still land" do
    Given "a registry that cannot be queried (offline)"
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs/cellbound-3d", name: "mac-box")
    responder = ->(_scope, _name) { raise Dev::RunnerRegistry::QueryError, "network is unreachable" }
    status = build_status(ui: ui, home: home, registry: CannedRegistry.new(&responder))

    When
    status.report

    Then
    rows_from(ui, "build-host · 1 slot · d3mlabs/cellbound-3d").take(3) == [
      [:frame, "build-host · 1 slot · d3mlabs/cellbound-3d", 0],
      [:note, "{{?}} reach: cannot tell — network is unreachable", 1],
      [:note, "{{?}} mac-box — service installed · runs as #{ME} · GitHub unreachable (network is unreachable)", 1],
    ]
    ui.rows.none? { |_kind, text, _depth| text.include?("{{x}}") }
    ui.rows.last == [:note, "posture: 1 slot · 3 facts · 0 drifted", 0]
  end

  # --- the invocation and the posture ----------------------------------------

  test "in a checkout, the invocation line names the families that repo's jobs reach, and the repo is bold in each from clause — #{what}" do
    Given "an agent family visible to dev and plans, an orchestrator family open to every repo, and a repo-scoped build host of snappy"
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-agent", scope: "d3mlabs", name: "box-agent")
    write_runner(home, "actions-runner-orchestrator", scope: "d3mlabs", name: "box-orchestrator")
    write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "box")
    ids = { "box-agent" => 1, "box-orchestrator" => 11, "box" => 21 }
    labels = { "box-agent" => AGENT_LABELS, "box-orchestrator" => ["ai-orchestrator"], "box" => ["snappy"] }
    responder = ->(_scope, name) { Dev::RunnerRegistry::Runner.new(id: ids.fetch(name), custom_labels: labels.fetch(name), status: "online") }
    registry = CannedRegistry.new(
      groups_by_runner: { 1 => CannedRegistry::AI_FLOW_GROUP, 11 => CannedRegistry::ORCHESTRATOR_GROUP },
      repos: { 7 => ["d3mlabs/dev", "d3mlabs/plans"] }, &responder
    )
    executor = CannedStatusExecutor.new(capture_results: cooperative_work_trees(home, "actions-runner-agent"))
    status = build_status(ui: ui, home: home, registry: registry, executor: executor, repo: repo)

    When
    status.report

    Then
    ui.rows.include?([:note, invocation, 0])
    ui.rows.include?([:note, from_clause, 1])

    Where
    what                        | repo                   | invocation                                                            | from_clause
    "an admitted org repo"      | "d3mlabs/dev"          | "this checkout (d3mlabs/dev) reaches: agent, orchestrator"            | "{{v}} reach: jobs from {{bold:d3mlabs/dev}}, d3mlabs/plans"
    "an org repo not selected"  | "d3mlabs/cellbound-3d" | "this checkout (d3mlabs/cellbound-3d) reaches: orchestrator"          | "{{v}} reach: jobs from d3mlabs/dev, d3mlabs/plans"
    "the build host's own repo" | "JPDuchesne/Snappy"    | "this checkout (JPDuchesne/Snappy) reaches: orchestrator, build-host" | "{{v}} reach: jobs from {{bold:JPDuchesne/snappy}}"
  end

  test "a checkout no family admits is a ✗ with register as the remedy, counted in the posture" do
    Given
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "box")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["snappy"], status: "online") }
    status = build_status(ui: ui, home: home, registry: CannedRegistry.new(&responder), repo: "d3mlabs/dev")

    When
    status.report

    Then
    ui.rows.last(2) == [
      [:note, "{{x}} this checkout (d3mlabs/dev) reaches no family — run `dev runner register` from this checkout", 0],
      [:note, "posture: 1 slot · 4 facts · 1 drifted", 0],
    ]
  end

  test "outside a checkout there is no invocation line" do
    Given
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "box")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["snappy"], status: "online") }
    status = build_status(ui: ui, home: home, registry: CannedRegistry.new(&responder))

    When
    status.report

    Then
    ui.rows.none? { |_kind, text, _depth| text.include?("this checkout") }
  end

  # --- the plain tier ---------------------------------------------------------

  test "through a pipe the same facts print plain: glyphs as characters, the reach clauses under their indent, no markup" do
    Given
    out = StringIO.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-orchestrator", scope: "d3mlabs", name: "box-orchestrator")
    write_runner(home, "actions-runner-orchestrator-2", scope: "d3mlabs", name: "box-orchestrator-2")
    responder = ->(_scope, name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["ai-orchestrator"], status: name == "box-orchestrator" ? "online" : "offline") }
    registry = CannedRegistry.new(group: CannedRegistry::ORCHESTRATOR_GROUP, &responder)
    status = build_status(out: out, home: home, registry: registry, repo: "d3mlabs/dev")

    When
    status.report

    Then
    out.string == <<~TEXT
      mac1 · darwin · launchd
      ✓ no org Brewfile shipped (nothing to check)
      orchestrator · 2 slots · d3mlabs
      ✓ reach: jobs from every d3mlabs repo
               via #{PINS_CLAUSE}
               runs-on ai-orchestrator
      ✓ box-orchestrator — online · service installed · runs as #{ME}
      ✗ box-orchestrator-2 (~/actions-runner-orchestrator-2) — offline on GitHub — the registration is not being run (re-run `dev runner register` to repair, or `dev runner unregister ~/actions-runner-orchestrator-2` to retire it)
      this checkout (d3mlabs/dev) reaches: orchestrator
      posture: 2 slots · 4 facts · 1 drifted
    TEXT
    !out.string.include?("{{")
    !out.string.include?("\e[")
  end

  # --- the host frame: the host rule --------------------------------------

  test "the host frame carries the runner user's facts: it exists, is logged in to GitHub as someone, and its token's expiry is read — #{what}" do
    Given
    ui = RecordingUi.new
    headers = expires_in.nil? ? "HTTP/2.0 200 OK\n\n{}" : expiring_in(expires_in)
    executor = CannedStatusExecutor.new(
      probe_results: { ["id", "-u", "runner"] => exists, as_runner("true") => true, as_runner("gh", "auth", "status") => logged_in },
      capture_results: {
        as_runner("gh", "api", "user", "--jq", ".login") => "d3mlabs-buildhost\n",
        as_runner("gh", "api", "user", "-i") => headers,
      },
    )
    status = build_status(ui: ui, executor: executor, host_identity: host_identity("runner"), host: "JPSFF", host_os: "linux")

    When
    status.report

    Then
    ui.rows.fetch(0) == [:frame, "JPSFF · linux · systemd", 0]
    ui.rows.include?([:note, expected, 1])

    Where
    what                        | exists | logged_in | expires_in | expected
    "all good, token expires"   | true   | true      | 365        | "{{v}} gh login: d3mlabs-buildhost (token expires #{(Date.today + 365).iso8601})"
    "a token with no expiry"    | true   | true      | nil        | "{{v}} gh login: d3mlabs-buildhost (token does not expire)"
    "a token about to expire"   | true   | true      | 10         | "{{x}} gh login: d3mlabs-buildhost (token expires #{(Date.today + 10).iso8601} — within 30 days; renew it, then `sudo -iu runner gh auth login --with-token`)"
    "no gh login"               | true   | false     | nil        | "{{x}} no gh login — `sudo -iu runner gh auth login --with-token`"
    "no such user"              | false  | false     | nil        | "{{x}} runner user runner missing (run `dev runner register`)"
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
    status = build_status(out: out, executor: executor, host_identity: host_identity("runner"), pins: pins, reach: reach, operator: "human")

    When
    status.report

    Then "one ? line naming who could not tell and how to find out; no ✗, no login remedy, no reach lines"
    out.string.include?("? gh login: cannot tell as human (sudo as runner needs a password here) — check with `sudo -iu runner gh auth status`")
    !out.string.include?("no gh login")
    !out.string.include?("✗ ")
    !out.string.include?("can read")
  end

  # dev#337: jobs upgrade dev through brew, so the prefix must be the
  # runner user's; status says whose it is.
  test "the host frame reports who owns the toolchain: the runner user, or drift with the chown" do
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

  test "with a checkout's lock, the host frame says what the runner user can and cannot read of it — the grant on each miss" do
    Given "two targets, one unreachable"
    ui = RecordingUi.new
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
    status = build_status(ui: ui, executor: executor, host_identity: host_identity("runner"), pins: pins, reach: reach)

    When
    status.report

    Then "inside the host frame, after the login"
    ui.rows.include?([:note, "{{x}} runner cannot read d3mlabs/unreal-engine (this checkout's lock) — gh api -X PUT repos/d3mlabs/unreal-engine/collaborators/d3mlabs-buildhost -f permission=pull", 1])
    ui.rows.include?([:note, "{{v}} runner can read package ghcr.io/d3mlabs/unreal-engine-build-base (this checkout's lock)", 1])
  end

  test "no host reach lines without a lock to read (projectless) or without a gh login to probe with" do
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
    !out.string.include?("can read")
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
    out.string.include?("✓ svc-runner can read d3mlabs/unreal-engine (this checkout's lock)")
  end

  test "the default identity factory is JobIdentity.for_host over the runner user and the executor" do
    Given "a status with no identity factory injected, a declared job identity on the host, JobIdentity intercepted at its platform seam"
    ui = RecordingUi.new
    executor = CannedStatusExecutor.new(probe_results: { ["id", "-u", "ue-builder"] => true })
    runner_user = host_identity("svc-runner")
    role = Dev::RunnerRole::Declaration.new(name: "ue-farm", labels: %w[ue gpu], job_identity: "ue-builder").bind(repo: "d3mlabs/cellbound-3d", version: nil)
    built = darwin_identity("ue-builder", executor, shared_root: Dir.mktmpdir, brew: nil, runner_user: "svc-runner")
    Dev::JobIdentity.expects(:for_host).once.with(user: "ue-builder", runner_user: "svc-runner", executor: executor).returns(built)
    status = build_status(ui: ui, executor: executor, host_identity: runner_user, roles: { "ue-farm" => role }, identity_factory: :default)

    When
    status.report

    Then "the identity's facts are the one for_host built"
    ui.rows.include?([:note, "{{v}} job identity ue-builder exists", 1])
  end

  test "without a host identity (a Mac) the host frame has no runner-user facts, and a slot is expected to run as the operator" do
    Given
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs/cellbound-3d", name: "mac-box")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 42, custom_labels: ["cellbound-3d"], status: "online") }
    status = build_status(ui: ui, home: home, registry: CannedRegistry.new(&responder))

    When
    status.report

    Then
    ui.rows.take(2) == [
      [:frame, "mac1 · darwin · launchd", 0],
      [:note, "{{v}} no org Brewfile shipped (nothing to check)", 1],
    ]
    ui.rows.include?([:note, "{{v}} mac-box — online · service installed · runs as #{ME}", 1])
  end

  # --- the host frame: the WSL runner host (dev#261) ---------------------

  test "off WSL the host frame has no WSL facts" do
    Given
    ui = RecordingUi.new
    status = build_status(ui: ui, wsl_runner_host: nil)

    When
    status.report

    Then
    ui.rows.none? { |_kind, text, _depth| text.include?("systemd") || text.include?("keepalive") }
  end

  test "a converged WSL runner host: five host facts, every one green" do
    Given
    ui = RecordingUi.new
    status = build_status(ui: ui, wsl_runner_host: wsl_runner_host)

    When
    status.report

    Then "inside the host frame, in order"
    first = ui.rows.index([:note, "{{v}} systemd running (the runner service is a systemd unit)", 1])
    ui.rows.slice(first, 5) == [
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

  # dev#571: a job under the runner's systemd service has neither interop
  # nor WSL_DISTRO_NAME, so the keepalive's task cannot even be named
  # there; the fact is unknown and the ledger goes on to the posture.
  test "a session that names no distro (a service) reads the keepalive as unknown, nameless, and the ledger goes on" do
    Given "a WSL runner host without interop whose task cannot be built"
    ui = RecordingUi.new
    wsl = wsl_runner_host(keepalive: nil)
    wsl.stubs(:task).raises(Dev::WslHost::DistroUnknownError, "WSL_DISTRO_NAME is not set")
    status = build_status(ui: ui, wsl_runner_host: wsl, host: "box", host_os: "linux")

    When
    status.check

    Then
    ui.rows == [
      [:frame, "box · linux · systemd", 0],
      [:note, "{{v}} systemd running (the runner service is a systemd unit)", 1],
      [:note, "{{?}} logon keepalive: cannot tell from this session (no WSL interop — a service or an ssh login) — run `dev runner status` from a shell opened in the distro on the Windows desktop", 1],
      [:note, "{{v}} no org Brewfile shipped (nothing to check)", 1],
      [:note, "posture: 0 slots · 3 facts · 0 drifted", 0],
    ]
  end

  # --- the host frame: the agent host --------------------------------------

  test "an agent family puts the agent host's facts in the host frame, and each slot's _work tree in its own line" do
    Given "an agent enrollment over an all-green host"
    ui = RecordingUi.new
    home = Dir.mktmpdir
    runner_dir = write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs", name: "mac-box")
    shared_root = Dir.mktmpdir
    executor = CannedStatusExecutor.new(
      probe_results: ALL_GREEN_PROBES,
      capture_results: {
        ["stat", "-f", "%Sg %Sp", File.join(runner_dir, "_work")] => "dev drwxrwsr-x\n",
        ["stat", "-f", "%Sg %Sp", shared_root] => "dev drwxrwsr-x\n",
        ["stat", "-f", "%Sg %Sp", "/opt/homebrew/var/homebrew/locks"] => "dev drwxrwsr-x\n",
        AGENT_SUDO_LIST => AGENT_RULES_HEADER,
      },
    )
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 42, custom_labels: AGENT_LABELS, status: "online") }
    status = build_status(
      ui: ui, home: home, registry: CannedRegistry.new(group: CannedRegistry::AI_FLOW_GROUP, repos: ["d3mlabs/dev"], &responder),
      executor: executor, shared_root: shared_root,
      brew: HUMAN_BREW, runner_user: "human", container_required: true,
    )

    When
    status.report

    Then "every agent host fact reads ok inside the host frame"
    ui.rows.take(10) == [
      [:frame, "mac1 · darwin · launchd", 0],
      [:note, "{{v}} job identity ai-agent exists", 1],
      [:note, "{{v}} human in the dev group", 1],
      [:note, "{{v}} ai-agent in the dev group", 1],
      [:note, "{{v}} runner → ai-agent sudoers edge (human → ai-agent, NOPASSWD:SETENV)", 1],
      [:note, "{{v}} no brew edge (#{NO_BREW_EDGE_REASON})", 1],
      [:note, "{{v}} data root #{shared_root} shared with group dev (setgid)", 1],
      [:note, "{{v}} brew lock dir /opt/homebrew/var/homebrew/locks shared with group dev (setgid, locks group-writable)", 1],
      [:note, "{{v}} colima installed (container engine)", 1],
      [:note, "{{v}} no org Brewfile shipped (nothing to check)", 1],
    ]

    # the slot's _work tree is the slot's fact, in the family frame, and it
    # holds (the slot's one finding is that it runs as this test's user,
    # not the identity's "human")
    ui.rows.none? { |_kind, text, depth| depth == 1 && text.include?("_work") && !text.include?("mac-box") }
    ui.rows.none? { |_kind, text, _depth| text.include?("_work tree not cooperative") }
    ui.rows.none? { |_kind, text, _depth| text.include?("{{x}}") && !text.include?("mac-box") }
  end

  # plans#59: the same facts on a Linux dev host, read with that platform's
  # probes through the Linux adapter — the runner user is dev#310's, the
  # engine fact says there is none to have.
  test "inspects a Linux agent host through the Linux adapter: the same facts, the runner user as the grantor, no engine" do
    Given "an agent enrollment on an all-green Linux host, for a repo that pins an image"
    out = StringIO.new
    home = Dir.mktmpdir
    runner_dir = write_runner(home, "actions-runner-x", scope: "d3mlabs", name: "box")
    data_root = Dir.mktmpdir
    executor = CannedStatusExecutor.new(
      probe_results: { ["id", "-u", "ai-agent"] => true, ["sudo", "-n", "-u", "ai-agent", "true"] => true },
      capture_results: {
        ["id", "-nG", "runner"] => "runner docker dev\n",
        ["id", "-nG", "ai-agent"] => "ai-agent dev\n",
        ["stat", "-c", "%G %A", File.join(runner_dir, "_work")] => "dev drwxrwsr-x\n",
        ["stat", "-c", "%G %A", data_root] => "dev drwxrwsr-x\n",
        ["stat", "-c", "%G %A", "/home/linuxbrew/.linuxbrew/var/homebrew/locks"] => "dev drwxrwsr-x\n",
        AGENT_SUDO_LIST => AGENT_RULES_HEADER,
      },
    )
    identity = Dev::JobIdentity::Linux.new(
      user: "ai-agent", runner_user: "runner", executor: executor, data_root: data_root, tap: nil,
      brew_executable: "/home/linuxbrew/.linuxbrew/bin/brew", owner_of: ->(_path) { "runner" },
    )
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: AGENT_LABELS, status: "online") }
    registry = CannedRegistry.new(group: CannedRegistry::AI_FLOW_GROUP, repos: ["d3mlabs/dev"], &responder)
    status = build_status(out: out, home: home, registry: registry, executor: executor, identity: identity, container_required: true)

    When
    status.report

    Then "every host fact reads ok but the engine, which names where the agent runs instead"
    out.string.include?("✓ job identity ai-agent exists")
    out.string.include?("✓ runner in the dev group")
    out.string.include?("✓ ai-agent in the dev group")
    out.string.include?("✓ runner → ai-agent sudoers edge (runner → ai-agent, NOPASSWD:SETENV)")
    out.string.include?("✓ no brew edge (#{NO_BREW_EDGE_REASON})")
    out.string.include?("✓ data root #{data_root} shared with group dev (setgid)")
    out.string.include?("✓ brew lock dir /home/linuxbrew/.linuxbrew/var/homebrew/locks shared with group dev (setgid, locks group-writable)")
    out.string.include?("✗ engine: ")
    out.string.include?("inside the project's container")
    !out.string.include?("_work tree not cooperative")
    out.string.scan("✗ engine:").length == 1
  end

  # dev#365 / dev#569: the drop-in is root-owned 0440, so the agent's rules
  # are read the way a job exercises them — through the runner → agent
  # edge, `-n`, list-only. No brew rule is the converged state; one that
  # runs brew as anyone, whatever its tags or path (a drop-in from before
  # the edge was retired, or a realpath one), is drift register rewrites.
  test "the agent's own sudo rules decide the brew edge fact — #{what}" do
    Given "an agent enrollment on a host where the agent's rules list #{what}"
    out = StringIO.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-x", scope: "d3mlabs", name: "box")
    executor = CannedStatusExecutor.new(
      probe_results: { ["sudo", "-n", "-u", "ai-agent", "true"] => true },
      capture_results: { AGENT_SUDO_LIST => rules },
    )
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: AGENT_LABELS, status: "online") }
    status = build_status(out: out, home: home, registry: CannedRegistry.new(&responder), executor: executor, brew: HUMAN_BREW, runner_user: "human")

    When
    status.report

    Then "the runner → agent edge reads ok, and the brew edge line names the shape found"
    out.string.include?("✓ runner → ai-agent sudoers edge (human → ai-agent, NOPASSWD:SETENV)")
    out.string.include?(expected)

    Where
    what                                     | rules                                                          | expected
    "no rules (the retired edge's absence)"  | AGENT_RULES_HEADER                                             | "✓ no brew edge (#{NO_BREW_EDGE_REASON})"
    "nothing at all (sudo -l refused)"       | ""                                                             | "✓ no brew edge (#{NO_BREW_EDGE_REASON})"
    "the retired edge, tags in sudo's order" | agent_rule("(human) SETENV: NOPASSWD: /opt/homebrew/bin/brew") | brew_edge_drift("(human) SETENV: NOPASSWD: /opt/homebrew/bin/brew")
    "a pre-dev#361 edge without SETENV"      | agent_rule("(human) NOPASSWD: /opt/homebrew/bin/brew")         | brew_edge_drift("(human) NOPASSWD: /opt/homebrew/bin/brew")
    "a realpath brew, as the runner user"    | agent_rule("(runner) SETENV: NOPASSWD: #{LINUXBREW_REALPATH}") | brew_edge_drift("(runner) SETENV: NOPASSWD: #{LINUXBREW_REALPATH}")
    "a rule for something other than brew"   | agent_rule("(human) NOPASSWD: /usr/bin/true")                  | "✓ no brew edge (#{NO_BREW_EDGE_REASON})"
  end

  test "a refused runner → agent probe is the finding: one red line, no prompt, and the agent's rules are not read" do
    Given "an agent enrollment on a host whose drop-in grants the operator nothing"
    out = StringIO.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-x", scope: "d3mlabs", name: "box")
    executor = CannedStatusExecutor.new(probe_results: { ["sudo", "-n", "-u", "ai-agent", "true"] => false })
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: AGENT_LABELS, status: "online") }
    status = build_status(out: out, home: home, registry: CannedRegistry.new(&responder), executor: executor, brew: HUMAN_BREW)

    When
    status.report

    Then
    out.string.include?("✗ runner → ai-agent sudoers edge missing (#{ME} → ai-agent, NOPASSWD:SETENV) — ai-agent's rules cannot be read without it (run `dev runner register`)")
    !out.string.include?("brew edge (")
    !out.string.include?("brew edge present")
  end

  test "a brewless host reads the same no-brew-edge fact: the posture does not depend on the prefix" do
    Given "an agent enrollment on a brewless host"
    out = StringIO.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-x", scope: "d3mlabs", name: "box")
    executor = CannedStatusExecutor.new(probe_results: { ["sudo", "-n", "-u", "ai-agent", "true"] => true })
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: AGENT_LABELS, status: "online") }
    status = build_status(out: out, home: home, registry: CannedRegistry.new(&responder), executor: executor, brew: nil)

    When
    status.report

    Then
    out.string.include?("✓ no brew edge (#{NO_BREW_EDGE_REASON})")
    !out.string.include?("brew lock dir")
  end

  test "flags every missing agent host fact, the slot's _work tree among the slot's own" do
    Given "an agent enrollment over a cold host"
    out = StringIO.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-x", scope: "d3mlabs", name: "box")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: AGENT_LABELS, status: "online") }
    status = build_status(
      out: out, home: home, registry: CannedRegistry.new(group: CannedRegistry::AI_FLOW_GROUP, repos: ["d3mlabs/dev"], &responder),
      shared_root: File.join(Dir.mktmpdir, "absent"),
      container_required: true,
    )

    When
    status.report

    Then "the host frame carries a failure marker per host fact (user, two memberships, the edge, shared root, engine), the slot one of its own"
    out.string.include?("✗ box (~/actions-runner-x) — _work tree not cooperative (group dev, setgid) (re-run `dev runner register` to repair, or `dev runner unregister ~/actions-runner-x` to retire it)")
    out.string.scan("✗ ").length == 7
  end

  test "the engine line appears only when the served repo builds in a container" do
    Given "an agent enrollment without a container"
    out = StringIO.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-x", scope: "d3mlabs", name: "box")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: AGENT_LABELS, status: "online") }
    status = build_status(out: out, home: home, registry: CannedRegistry.new(&responder), container_required: false)

    When
    status.report

    Then
    !out.string.include?("colima")
  end

  test "no agent host facts without an agent family" do
    Given
    out = StringIO.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-orchestrator", scope: "d3mlabs", name: "box-orchestrator")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["ai-orchestrator"], status: "online") }
    status = build_status(out: out, home: home, registry: CannedRegistry.new(group: CannedRegistry::ORCHESTRATOR_GROUP, &responder))

    When
    status.report

    Then
    !out.string.include?("job identity")
    !out.string.include?("_work")
  end

  test "the agent host's facts are inspected when the agent user is on the host, with no agent family enrolled" do
    Given "an orchestrator-only host whose agent user exists (register converged it; the agent slots were retired)"
    out = StringIO.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-orchestrator", scope: "d3mlabs", name: "box-orchestrator")
    executor = CannedStatusExecutor.new(probe_results: { ["id", "-u", "ai-agent"] => true })
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["ai-orchestrator"], status: "online") }
    status = build_status(out: out, home: home, registry: CannedRegistry.new(group: CannedRegistry::ORCHESTRATOR_GROUP, &responder), executor: executor)

    When
    status.report

    Then "the agent host facts land, the user green and the rest red"
    out.string.include?("✓ job identity ai-agent exists")
    out.string.include?("✗ runner → ai-agent sudoers edge missing")
  end

  # --- --check (dev#571): the host's posture alone, GitHub not asked ---------

  # A job runs this after every `dev up`, on its own identity: the host
  # frame and the posture, nothing GitHub would have to be asked for. The
  # roles enrolled are read from the records' pools, as for a slot GitHub
  # has lost — an org agent family names its pool.
  test "--check renders the host frame and the posture alone — no family frame — and never asks GitHub when every fact holds" do
    Given "a green Linux agent host with an org agent family and the orchestrator pool, and a registry that must not be asked"
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-agent", scope: "d3mlabs", name: "box-agent", pool: "ai-flow")
    write_runner(home, "actions-runner-orchestrator", scope: "d3mlabs", name: "box-orchestrator", pool: "ai-orchestrator")
    registry = CannedRegistry.new { |_scope, name| raise "GitHub was asked about #{name}" }
    data_root = Dir.mktmpdir
    executor = CannedStatusExecutor.new(
      probe_results: { ["id", "-u", "ai-agent"] => true, ["sudo", "-n", "-u", "ai-agent", "true"] => true },
      capture_results: {
        ["id", "-nG", "runner"] => "runner docker dev\n",
        ["id", "-nG", "ai-agent"] => "ai-agent dev\n",
        ["stat", "-c", "%G %A", data_root] => "dev drwxrwsr-x\n",
        AGENT_SUDO_LIST => AGENT_RULES_HEADER,
      },
    )
    identity = Dev::JobIdentity::Linux.new(
      user: "ai-agent", runner_user: "runner", executor: executor, data_root: data_root, tap: nil, brew_executable: nil,
      owner_of: ->(_path) { "runner" },
    )
    status = build_status(ui: ui, home: home, registry: registry, executor: executor, identity: identity, host: "box", host_os: "linux")

    When
    status.check

    Then "the ledger is the host frame's facts and the posture; the slots are counted, not inspected"
    ui.rows == [
      [:frame, "box · linux · systemd", 0],
      [:note, "{{v}} job identity ai-agent exists", 1],
      [:note, "{{v}} runner in the dev group", 1],
      [:note, "{{v}} ai-agent in the dev group", 1],
      [:note, "{{v}} runner → ai-agent sudoers edge (runner → ai-agent, NOPASSWD:SETENV)", 1],
      [:note, "{{v}} no brew edge (#{NO_BREW_EDGE_REASON})", 1],
      [:note, "{{v}} data root #{data_root} shared with group dev (setgid)", 1],
      [:note, "{{v}} no org Brewfile shipped (nothing to check)", 1],
      [:note, "posture: 2 slots · 7 facts · 0 drifted", 0],
    ]
  end

  test "--check raises PostureDriftError once the ledger is printed, when a fact is red — the message sums the drift and points at the lines" do
    Given "an org agent family on a cold host"
    ui = RecordingUi.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-agent", scope: "d3mlabs", name: "box-agent", pool: "ai-flow")
    registry = CannedRegistry.new { |_scope, name| raise "GitHub was asked about #{name}" }
    status = build_status(ui: ui, home: home, registry: registry, shared_root: File.join(Dir.mktmpdir, "absent"))

    When
    error = assert_raises(Dev::RunnerStatus::PostureDriftError) { status.check }

    Then "the host frame and the posture were rendered before the raise, and the message names the count"
    ui.rows.fetch(0) == [:frame, "mac1 · darwin · launchd", 0]
    ui.rows.include?([:note, "{{x}} job identity ai-agent exists", 1])
    ui.rows.last == [:note, "posture: 1 slot · 6 facts · 5 drifted", 0]
    error.message == "host posture: 5 of 6 facts drifted — the red lines above name each remedy (`dev runner register` converges the host; `dev up` the tooling)"
  end

  test "--check on a host with no enrollments and nothing drifted returns quietly" do
    Given
    ui = RecordingUi.new
    status = build_status(ui: ui, registry: CannedRegistry.new { |_scope, name| raise "GitHub was asked about #{name}" })

    When
    status.check

    Then
    ui.rows == [
      [:frame, "mac1 · darwin · launchd", 0],
      [:note, "{{v}} no org Brewfile shipped (nothing to check)", 1],
      [:note, "posture: 0 slots · 1 fact · 0 drifted", 0],
    ]
  end

  # The Mac's cellbound-3d slot: a repo-scoped agent family records no
  # pool (Default), so without GitHub its role reads as a build host — the
  # agent user on the host is what says the host is an agent host.
  test "--check inspects the agent host through the agent user when the only agent family is repo-scoped (its record names no pool)" do
    Given "a repo-scoped agent slot and the agent user on the host, the edge missing"
    out = StringIO.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs/cellbound-3d", name: "mac-agent")
    executor = CannedStatusExecutor.new(probe_results: { ["id", "-u", "ai-agent"] => true, ["sudo", "-n", "-u", "ai-agent", "true"] => false })
    registry = CannedRegistry.new { |_scope, name| raise "GitHub was asked about #{name}" }
    status = build_status(out: out, home: home, registry: registry, executor: executor)

    When
    error = assert_raises(Dev::RunnerStatus::PostureDriftError) { status.check }

    Then
    out.string.include?("✓ job identity ai-agent exists")
    out.string.include?("✗ runner → ai-agent sudoers edge missing")
    error.message.start_with?("host posture: ")
  end

  test "--check skips a build-host-only machine's agent facts: no agent family, no agent user" do
    Given
    out = StringIO.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "box")
    status = build_status(out: out, home: home, registry: CannedRegistry.new { |_scope, name| raise "GitHub was asked about #{name}" })

    When
    status.check

    Then
    !out.string.include?("job identity")
    out.string.include?("posture: 1 slot · 1 fact · 0 drifted")
  end

  # --- the host frame: the tooling -------------------------------------------

  test "host tooling reads the org Brewfile check — #{what}" do
    Given
    out = StringIO.new
    brewfile = existing_file
    executor = CannedStatusExecutor.new(probe_results: { ["brew", "bundle", "check", "--file=#{brewfile}"] => converged })
    status = build_status(out: out, executor: executor, brewfile_path: brewfile)

    When
    status.report

    Then
    out.string.include?(expected.call(brewfile))

    Where
    what        | converged | expected
    "converged" | true      | ->(path) { "✓ host tooling matches #{path} (dev #{Dev::Version.current})" }
    "behind"    | false     | ->(path) { "✗ host tooling behind #{path} (dev #{Dev::Version.current}) — run `dev up`" }
  end

  # dev#613: the host half is the prefix owner's to converge (HostService
  # skips the layer for anyone else), so on a Linux host handed over the
  # remedy is `dev up` as the runner user — spelled with the name the host
  # resolves, outside a checkout — and the reader's own `dev up` when the
  # reader owns the prefix (a job as the runner user, a host not handed
  # over).
  test "a tooling line behind on a Linux host names the by-hand `dev up` as the prefix's owner — #{what}" do
    Given "a Brewfile the host is behind, and #{what}"
    out = StringIO.new
    brewfile = existing_file
    executor = CannedStatusExecutor.new(probe_results: { ["brew", "bundle", "check", "--file=#{brewfile}"] => false, ["id", "-u", name] => true })
    identity = host_identity(name, brew: "/home/linuxbrew/.linuxbrew/bin/brew", owner_of: ->(_path) { owner })
    status = build_status(out: out, executor: executor, brewfile_path: brewfile, host_identity: identity, operator: operator, host: "box", host_os: "linux")

    When
    status.report

    Then
    out.string.include?("✗ host tooling behind #{brewfile} (dev #{Dev::Version.current}) — #{remedy}")

    Where
    what                                                | name     | owner        | operator     | remedy
    "the prefix ci's, read by the operator"             | "ci"     | "ci"         | "jpduchesne" | "`sudo -iu ci dev up` (outside a checkout)"
    "the prefix runner's, read by the operator"         | "runner" | "runner"     | "jpduchesne" | "`sudo -iu runner dev up` (outside a checkout)"
    "the prefix ci's, read by ci itself (a job)"        | "ci"     | "ci"         | "ci"         | "run `dev up`"
    "the prefix the operator's own (not handed over)"   | "runner" | "jpduchesne" | "jpduchesne" | "run `dev up`"
  end

  # dev#613: on a host registered `--as ci`, status used to build its host
  # identity on the rule's default and report `runner user runner missing`
  # while probing the wrong user's login. The identity's name now comes
  # from the prefix's owner (RunnerUser.for_host), and every host fact and
  # remedy is spelled with it.
  test "on a host handed to ci, the host frame reads ci throughout: the user, its toolchain, its login's probes and remedies" do
    Given "the identity the host resolves on a prefix owned by ci (the rule's default user is nowhere on it), with no gh login"
    out = StringIO.new
    executor = CannedStatusExecutor.new(probe_results: {
      ["id", "-u", "ci"] => true, as_runner("true", user: "ci") => true, as_runner("gh", "auth", "status", user: "ci") => false,
    })
    identity = host_identity("ci", brew: "/home/linuxbrew/.linuxbrew/bin/brew", owner_of: ->(_path) { "ci" })
    status = build_status(out: out, executor: executor, host_identity: identity, host: "box", host_os: "linux")

    When
    status.report

    Then
    out.string.include?("✓ runner user ci exists")
    out.string.include?("✓ toolchain: /home/linuxbrew/.linuxbrew owned by ci")
    out.string.include?("✗ no gh login — `sudo -iu ci gh auth login --with-token`")
    !out.string.include?("user runner")
    !out.string.include?("sudo -iu runner")
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

  # The recorded rows from the frame of that title on.
  def rows_from(ui, frame_title)
    ui.rows.drop_while { |row| row != [:frame, frame_title, 0] }
  end

  # A .runner record the way config.sh writes it (UTF-8 BOM + JSON), with
  # svc.sh's `.service` marker unless `service: false`.
  # A converged slot's dir. On the Mac rule (the default host here) its
  # `.env` carries the jobs' gh token (JobGhToken); `env:` replaces the
  # whole file, nil leaves none.
  def write_runner(home, dir_name, scope:, name:, pool: nil, service: true, env: "LANG=C\nGH_TOKEN=ghp_machine\n")
    dir = File.join(home, dir_name)
    FileUtils.mkdir_p(dir)
    record = { "agentId" => 1, "agentName" => name, "gitHubUrl" => "https://github.com/#{scope}" }
    record["poolName"] = pool if pool
    File.write(File.join(dir, ".runner"), "\uFEFF#{JSON.generate(record)}")
    File.write(File.join(dir, ".service"), "actions.runner.#{scope.tr("/", "-")}.#{name}.service") if service
    File.write(File.join(dir, ".env"), env) if env
    dir
  end

  # The Darwin identity's `_work` stat answers for cooperative trees under
  # each of the dirs, created on the way.
  def cooperative_work_trees(home, *dir_names)
    dir_names.to_h do |dir_name|
      work = File.join(home, dir_name, "_work")
      FileUtils.mkdir_p(work)
      [["stat", "-f", "%Sg %Sp", work], "dev drwxrwsr-x\n"]
    end
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

  # The job identity status reads a user's facts through: by default a
  # Mac's, over the same canned executor, with `runner_user` as the runner
  # user — this test's user by default, since it owns the enrollment dirs;
  # "human" where the sudoers edge's grantor must differ from the identity
  # — a brew (if any) whose prefix is that user's, and no tap.
  def darwin_identity(user, executor, shared_root:, brew:, runner_user:)
    Dev::JobIdentity::Darwin.new(
      user: user, runner_user: runner_user, executor: executor, data_root: shared_root,
      home_dev: File.join(Dir.mktmpdir, "absent"), launch_agents_dir: Dir.mktmpdir,
      brew_executable: brew, owner_of: ->(_path) { runner_user }, tap: nil,
    )
  end

  # The roles at hand default to the aliases — ai-flow's agent and
  # orchestrator as they were builtin — so a host's slots read as they did;
  # `identity:` is one adapter for every user (a Linux host's), else the
  # Mac's per user. The operator is the runner user on a Mac: the same name
  # by default, since every slot is expected to run as it.
  def build_status(out: StringIO.new, ui: Dev::NoUi.new(out: out), home: Dir.mktmpdir, registry: CannedRegistry.new,
                   executor: CannedStatusExecutor.new, shared_root: Dir.mktmpdir, brew: nil, runner_user: ME, identity: nil,
                   identity_factory: ->(user) { identity || darwin_identity(user, executor, shared_root: shared_root, brew: brew, runner_user: runner_user) },
                   roles: Dev::RunnerRoleAliases::ALL, brewfile_path: nil,
                   container_required: false, host_identity: nil, pins: [], repo: nil, reach: nil, reach_factory: ->(_identity) { reach },
                   wsl_runner_host: nil, host: "mac1", host_os: "darwin", operator: runner_user)
    # :default leaves RunnerStatus's own factory in place.
    reach_wiring = reach_factory == :default ? {} : { reach_factory: reach_factory }
    identity_wiring = identity_factory == :default ? {} : { identity_factory: identity_factory }
    Dev::RunnerStatus.new(
      pins: pins,
      repo: repo,
      **reach_wiring,
      **identity_wiring,
      # The WSL runner host (dev#261): nil is any host but a WSL2 distro.
      wsl_runner_host: wsl_runner_host,
      discovery: Dev::RunnerDiscovery.new(home: home),
      registry: registry,
      ui: ui,
      executor: executor,
      operator: operator,
      host: host,
      host_os: host_os,
      host_identity: host_identity,
      roles: roles,
      brewfile_path: brewfile_path,
      container_required: container_required,
    )
  end
end

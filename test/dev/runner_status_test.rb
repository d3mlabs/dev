# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/runner_discovery"
require "dev/runner_registry"
require "dev/deps/dependency"
require "dev/host_reach"
require "dev/runner_status"
require "dev/runner_user"
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
  def initialize(&responder)
    @responder = responder
  end

  def find(scope:, name:)
    @responder ? @responder.call(scope, name) : nil
  end
end unless defined?(CannedRegistry)

transform!(RSpock::AST::Transformation)
class Dev::RunnerStatusTest < Minitest::Test
  include SorbetHelper

  ALL_GREEN_PROBES = {
    ["id", "-u", "ai-agent"] => true,
    ["dseditgroup", "-o", "checkmember", "-m", "human", "ai"] => true,
    ["dseditgroup", "-o", "checkmember", "-m", "ai-agent", "ai"] => true,
    ["brew", "list", "--formula", "colima"] => true,
  }.freeze

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

  test "flags an enrollment GitHub has lost" do
    Given "a .runner record whose runner is gone server-side"
    out = StringIO.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs", name: "mac-box")
    status = build_status(out: out, home: home, registry: CannedRegistry.new)

    When "reporting"
    status.report

    Then
    out.string.include?("[!!] gone on GitHub")
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
    out.string.include?("Runner 'JPSFF' (~/actions-runner):")
    out.string.include?("[ok] labels: snappy")
    out.string.include?("[!!] offline on GitHub — the registration is not being run (re-run `dev runner register`)")
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
    out.string.include?("[!!] runs as #{Etc.getpwuid(Process.uid).name}, not svc-runner — drift (re-run `dev runner register`)")
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
    out.string.include?("Runner 'JPSFF' (#{File.join(runner_home, "actions-runner-snappy")}):")
    out.string.include?("[ok] runs as #{me}")
  end

  test "the host identity section: the runner user exists, is logged in to GitHub as someone, and its token's expiry is read — #{what}" do
    Given
    out = StringIO.new
    headers = expires_in.nil? ? "HTTP/2.0 200 OK\n\n{}" : expiring_in(expires_in)
    executor = CannedStatusExecutor.new(
      probe_results: { ["id", "-u", "runner"] => exists, ["sudo", "-u", "runner", "-H", "gh", "auth", "status"] => logged_in },
      capture_results: {
        ["sudo", "-u", "runner", "-H", "gh", "api", "user", "--jq", ".login"] => "d3mlabs-buildhost\n",
        ["sudo", "-u", "runner", "-H", "gh", "api", "user", "-i"] => headers,
      },
    )
    status = build_status(out: out, executor: executor, host_identity: host_identity("runner"))

    When
    status.report

    Then
    out.string.include?("Host identity (runner):")
    out.string.include?(expected)

    Where
    what                        | exists | logged_in | expires_in | expected
    "all good, token expires"   | true   | true      | 365        | "[ok] gh login: d3mlabs-buildhost (token expires #{(Date.today + 365).iso8601})"
    "a token with no expiry"    | true   | true      | nil        | "[ok] gh login: d3mlabs-buildhost (token does not expire)"
    "a token about to expire"   | true   | true      | 10         | "[!!] gh login: d3mlabs-buildhost (token expires #{(Date.today + 10).iso8601} — within 30 days; renew it, then `sudo -iu runner gh auth login --with-token`)"
    "no gh login"               | true   | false     | nil        | "[!!] no gh login — `sudo -iu runner gh auth login --with-token`"
    "no such user"              | false  | false     | nil        | "[!!] user runner exists (run `dev runner register`)"
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
    executor = CannedStatusExecutor.new(probe_results: { ["id", "-u", "runner"] => true, ["sudo", "-u", "runner", "-H", "gh", "auth", "status"] => true },
      capture_results: { ["sudo", "-u", "runner", "-H", "gh", "api", "user", "--jq", ".login"] => "d3mlabs-buildhost\n" })
    status = build_status(out: out, executor: executor, host_identity: host_identity("runner"), pins: pins, reach: reach)

    When
    status.report

    Then
    out.string.include?("Host reach (runner, this checkout's lock):")
    out.string.include?("[!!] cannot read d3mlabs/unreal-engine — gh api -X PUT repos/d3mlabs/unreal-engine/collaborators/d3mlabs-buildhost -f permission=pull")
    out.string.include?("[ok] can read package ghcr.io/d3mlabs/unreal-engine-build-base")
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
    executor = CannedStatusExecutor.new(probe_results: { ["id", "-u", "svc-runner"] => true, ["sudo", "-u", "svc-runner", "-H", "gh", "auth", "status"] => true },
      capture_results: { ["sudo", "-u", "svc-runner", "-H", "gh", "api", "user", "--jq", ".login"] => "d3mlabs-buildhost\n" })
    status = build_status(out: out, executor: executor, host_identity: identity, pins: pins, reach_factory: :default)

    When
    status.report

    Then
    out.string.include?("[ok] can read d3mlabs/unreal-engine")
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
      capture_results: { ["stat", "-f", "%Sg %Sp", work] => "ai drwxrwsr-x\n" },
    )
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 42, custom_labels: ["ai-build"], status: "online") }
    status = build_status(
      out: out, home: home, registry: CannedRegistry.new(&responder),
      executor: executor, shared_root: shared_root,
      sudoers_path: existing_file, container_required: true,
    )

    When "reporting"
    status.report

    Then "every agent host fact reads ok"
    out.string.include?("Agent host")
    !out.string.include?("[!!]")
    out.string.include?("agent user ai-agent")
    out.string.include?("sudoers edge")
    out.string.include?("_work tree")
    out.string.include?("shared root")
    out.string.include?("colima")
  end

  test "flags every missing agent host fact" do
    Given "an agent-labeled enrollment over a cold host"
    out = StringIO.new
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-x", scope: "d3mlabs", name: "box")
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["ai-learn"], status: "online") }
    status = build_status(
      out: out, home: home, registry: CannedRegistry.new(&responder),
      sudoers_path: File.join(Dir.mktmpdir, "absent"),
      shared_root: File.join(Dir.mktmpdir, "absent"),
      container_required: true,
    )

    When "reporting"
    status.report

    Then "the report carries failure markers for each fact"
    out.string.scan("[!!]").length >= 5
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
    out.string.include?("[ok] host tooling")
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
  def host_identity(name, home: Dir.mktmpdir)
    Dev::RunnerUser.new(name: name, home_of: ->(_user) { home })
  end

  def build_status(out:, home: Dir.mktmpdir, registry: CannedRegistry.new,
                   executor: CannedStatusExecutor.new, shared_root: Dir.mktmpdir,
                   sudoers_path: File.join(Dir.mktmpdir, "absent"), brewfile_path: nil,
                   container_required: false, host_identity: nil, pins: [], reach: nil, reach_factory: ->(_identity) { reach })
    # :default leaves RunnerStatus's own reach factory in place.
    reach_wiring = reach_factory == :default ? {} : { reach_factory: reach_factory }
    Dev::RunnerStatus.new(
      pins: pins,
      **reach_wiring,
      discovery: Dev::RunnerDiscovery.new(home: home),
      registry: registry,
      out: out,
      executor: executor,
      runner_user: "human",
      host_identity: host_identity,
      shared_root: shared_root,
      sudoers_path: sudoers_path,
      brewfile_path: brewfile_path,
      container_required: container_required,
    )
  end
end

# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/runner_discovery"
require "dev/runner_registry"
require "dev/runner_status"
require "fileutils"
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
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 42, custom_labels: %w[ai-ask ai-edit]) }
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
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 42, custom_labels: ["ai-build"]) }
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
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["ai-learn"]) }
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
    responder = ->(_scope, _name) { Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["ai-build"]) }
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

  def build_status(out:, home: Dir.mktmpdir, registry: CannedRegistry.new,
                   executor: CannedStatusExecutor.new, shared_root: Dir.mktmpdir,
                   sudoers_path: File.join(Dir.mktmpdir, "absent"), brewfile_path: nil,
                   container_required: false)
    Dev::RunnerStatus.new(
      discovery: Dev::RunnerDiscovery.new(home: home),
      registry: registry,
      out: out,
      executor: executor,
      runner_user: "human",
      shared_root: shared_root,
      sudoers_path: sudoers_path,
      brewfile_path: brewfile_path,
      container_required: container_required,
    )
  end
end

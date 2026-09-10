# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/runner_status"
require "dev/runner_setup_config"
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

transform!(RSpock::AST::Transformation)
class Dev::RunnerStatusTest < Minitest::Test
  ALL_GREEN_PROBES = {
    ["id", "-u", "ai-agent"] => true,
    ["dseditgroup", "-o", "checkmember", "-m", "human", "ai"] => true,
    ["dseditgroup", "-o", "checkmember", "-m", "ai-agent", "ai"] => true,
    ["brew", "list", "--formula", "colima"] => true,
  }.freeze

  test "reports an unregistered runner" do
    Given "a bare-label config with no registration on disk"
    out = StringIO.new
    status = build_status(labels: "gamebox", out: out)

    When "reporting"
    status.report

    Then "the registration line says so and no posture section appears"
    out.string.include?("not registered")
    !out.string.include?("Agent posture")
  end

  test "reports the registered scope read from the runner's own record" do
    Given "a registered runner dir"
    out = StringIO.new
    runner_dir = Dir.mktmpdir
    File.write(
      File.join(runner_dir, ".runner"),
      JSON.dump({ "gitHubUrl" => "https://github.com/d3mlabs/cellbound-3d" }),
    )
    status = build_status(labels: "gamebox", out: out, runner_dir: runner_dir)

    When "reporting"
    status.report

    Then
    out.string.include?("registered: d3mlabs/cellbound-3d")
  end

  test "inspects the full agent posture for agent-capability labels" do
    Given "an agent-labeled config over an all-green host"
    out = StringIO.new
    runner_dir = Dir.mktmpdir
    work = File.join(runner_dir, "_work")
    shared_root = Dir.mktmpdir
    executor = CannedStatusExecutor.new(
      probe_results: ALL_GREEN_PROBES,
      capture_results: { ["stat", "-f", "%Sg %Sp", work] => "ai drwxrwsr-x\n" },
    )
    FileUtils.mkdir_p(work)
    File.write(
      File.join(runner_dir, ".runner"),
      JSON.dump({ "gitHubUrl" => "https://github.com/d3mlabs/cellbound-3d" }),
    )
    status = build_status(
      labels: "ai-build", out: out, runner_dir: runner_dir,
      executor: executor, shared_root: shared_root,
      sudoers_path: existing_file, container_required: true,
    )

    When "reporting"
    status.report

    Then "every posture fact reads ok"
    out.string.include?("Agent posture")
    !out.string.include?("[!!]")
    out.string.include?("agent user ai-agent")
    out.string.include?("sudoers edge")
    out.string.include?("_work tree")
    out.string.include?("shared root")
    out.string.include?("colima")
  end

  test "flags every missing posture fact" do
    Given "an agent-labeled config over a cold host"
    out = StringIO.new
    status = build_status(
      labels: "ai-learn", out: out,
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
    Given "an agent-labeled config without a container"
    out = StringIO.new
    status = build_status(labels: "ai-build", out: out, container_required: false)

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
    status = build_status(labels: "gamebox", out: out, executor: executor, brewfile_path: brewfile)

    # and a status with no Brewfile shipped
    out_none = StringIO.new
    status_none = build_status(labels: "gamebox", out: out_none, brewfile_path: nil)

    When "reporting both"
    status.report
    status_none.report

    Then
    out.string.include?("[ok] host tooling")
    out_none.string.include?("no org Brewfile")
  end

  private

  def existing_file
    path = File.join(Dir.mktmpdir, "present")
    File.write(path, "x")
    path
  end

  def build_status(labels:, out:, runner_dir: File.join(Dir.mktmpdir, "absent-runner"),
                   executor: CannedStatusExecutor.new, shared_root: Dir.mktmpdir,
                   sudoers_path: File.join(Dir.mktmpdir, "absent"), brewfile_path: nil,
                   container_required: false)
    Dev::RunnerStatus.new(
      config: Dev::RunnerSetupConfig.new(labels: labels),
      runner_dir: runner_dir,
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

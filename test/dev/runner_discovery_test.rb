# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/runner_discovery"
require "tmpdir"
require "fileutils"
require "json"

transform!(RSpock::AST::Transformation)
class Dev::RunnerDiscoveryTest < Minitest::Test
  test "enrollments reads every configured actions-runner dir under home" do
    Given "a home with two configured runner dirs and one unconfigured"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs", name: "JeanPhiippesMBP")
    write_runner(home, "actions-runner-ue-engine", scope: "d3mlabs/unreal-engine", name: "gaming-box")
    FileUtils.mkdir_p(File.join(home, "actions-runner-fresh")) # downloaded, never configured

    When "discovering"
    enrollments = Dev::RunnerDiscovery.new(home: home).enrollments

    Then "each .runner record surfaces as an enrollment, dir-ordered; the unconfigured dir is silent"
    enrollments.map { |e| [e.dir, e.scope, e.name] } == [
      [File.join(home, "actions-runner-cellbound3d"), "d3mlabs", "JeanPhiippesMBP"],
      [File.join(home, "actions-runner-ue-engine"), "d3mlabs/unreal-engine", "gaming-box"],
    ]
  end

  test "enrollments sees the suffixless legacy dir too — a hand-made ~/actions-runner is an enrollment (#238)" do
    Given "a home with a suffixless runner dir beside a dev-made one, both configured for one scope"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner", scope: "JPDuchesne/snappy", name: "JPSFF")
    write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    write_runner(home, "actions-runners-not-one", scope: "d3mlabs", name: "nope") # a sibling name, not a runner dir

    When "discovering"
    enrollments = Dev::RunnerDiscovery.new(home: home).enrollments

    Then "both enrollments surface, the legacy dir first; the look-alike dir does not"
    enrollments.map(&:dir) == [File.join(home, "actions-runner"), File.join(home, "actions-runner-snappy")]
  end

  test "an enrollment knows whether its service is installed (the .service marker svc.sh writes)" do
    Given "two enrollments, one with a .service marker"
    home = Dir.mktmpdir
    with_service = write_runner(home, "actions-runner", scope: "JPDuchesne/snappy", name: "JPSFF")
    File.write(File.join(with_service, ".service"), "actions.runner.JPDuchesne-snappy.JPSFF.service\n")
    write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")

    When "discovering"
    installed = Dev::RunnerDiscovery.new(home: home).enrollments.map(&:service_installed)

    Then
    installed == [true, false]
  end

  test "display_dir is the dir relative to home with a ~, or absolute when outside home" do
    Given "an enrollment under home and one elsewhere"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    elsewhere = Dir.mktmpdir
    write_runner(elsewhere, "actions-runner-ue", scope: "d3mlabs/unreal-engine", name: "box")

    When "reading each"
    under_home = Dev::RunnerDiscovery.new(home: home).enrollments.fetch(0)
    outside = Dev::RunnerDiscovery.read(File.join(elsewhere, "actions-runner-ue"), home: home)

    Then
    under_home.display_dir == "~/actions-runner-snappy"
    outside.display_dir == File.join(elsewhere, "actions-runner-ue")
  end

  test "enrollments_for lists every local enrollment serving a scope, dir-ordered, and nothing else" do
    Given "two enrollments for one scope and one for another"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner", scope: "JPDuchesne/snappy", name: "JPSFF")
    write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs/cellbound-3d", name: "JPSFF")
    write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    discovery = Dev::RunnerDiscovery.new(home: home)

    Expect "the plural lookup is exact on the .runner scope"
    discovery.enrollments_for("JPDuchesne/snappy").map(&:dir) ==
      [File.join(home, "actions-runner"), File.join(home, "actions-runner-snappy")]
    discovery.enrollments_for("d3mlabs/cellbound-3d").map(&:dir) == [File.join(home, "actions-runner-cellbound3d")]
    discovery.enrollments_for("d3mlabs") == []
  end

  test "for_scope is the only enrollment serving a scope — nil when several do, so plurality never picks a winner" do
    Given "two enrollments for one scope"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner", scope: "JPDuchesne/snappy", name: "JPSFF")
    write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")

    Expect
    Dev::RunnerDiscovery.new(home: home).for_scope("JPDuchesne/snappy").nil?
  end

  test "for_scope finds the enrollment serving a scope regardless of its dir name" do
    Given "an org enrollment living in a repo-named dir (its pre-org history)"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs", name: "JeanPhiippesMBP")

    When "looking up the org scope"
    enrollment = Dev::RunnerDiscovery.new(home: home).for_scope("d3mlabs")

    Then "the dir name does not matter — the .runner record does"
    enrollment.dir == File.join(home, "actions-runner-cellbound3d")
    enrollment.name == "JeanPhiippesMBP"
  end

  test "for_scope is nil when no enrollment serves the scope" do
    Given "a home with only a repo-scoped enrollment"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs/cellbound-3d", name: "box")

    Expect
    Dev::RunnerDiscovery.new(home: home).for_scope("d3mlabs").nil?
  end

  test "read parses the BOM config.sh writes and nils out garbage" do
    Given "a dir whose .runner is not JSON"
    home = Dir.mktmpdir
    dir = File.join(home, "actions-runner-broken")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, ".runner"), "not json")

    Expect "garbage reads as unconfigured, never raises"
    Dev::RunnerDiscovery.read(dir).nil?
    Dev::RunnerDiscovery.new(home: home).enrollments == []
  end

  private

  # A .runner record the way config.sh writes it: UTF-8 BOM + JSON with
  # gitHubUrl/agentName (scope "owner" or "owner/repo").
  def write_runner(home, dir_name, scope:, name:)
    dir = File.join(home, dir_name)
    FileUtils.mkdir_p(dir)
    record = { "agentName" => name, "gitHubUrl" => "https://github.com/#{scope}", "workFolder" => "_work" }
    File.write(File.join(dir, ".runner"), "\uFEFF#{JSON.pretty_generate(record)}")
    dir
  end
end

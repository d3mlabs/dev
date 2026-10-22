# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/apt_integration"
require "dev/deps/apt_repository"
require "dev/deps/dependency"
require "dev/debian_host"
require "dev/privileged_steps"
require "stringio"
require "tmpdir"
require "fileutils"

# Records every process the integration runs. dpkg answers from canned
# facts; everything under sudo is recorded and succeeds unless +failing+
# names it. Files (keyrings, sources) are real, under a tmp root.
class RecordedAptExecutor
  attr_reader :runs

  def initialize(installed: {}, foreign_archs: [], arch: "amd64", failing: nil)
    @installed = installed # package => version
    @foreign_archs = foreign_archs
    @arch = arch
    @failing = failing
    @runs = []
  end

  def run(*cmd)
    @runs << cmd
    @failing.nil? || !cmd.join(" ").include?(@failing)
  end

  def capture(*cmd)
    case cmd
    when %w[dpkg --print-architecture] then "#{@arch}\n"
    when %w[dpkg --print-foreign-architectures] then @foreign_archs.map { |a| "#{a}\n" }.join
    when ->(c) { c[0, 2] == %w[dpkg-query -W] }
      version = @installed[cmd.last]
      version ? "install ok installed #{version}\n" : ""
    else ""
    end
  end

  def sudo_runs
    @runs.select { |bin, *_rest| bin == "sudo" }
  end
end unless defined?(RecordedAptExecutor)

transform!(RSpock::AST::Transformation)
class Dev::Deps::AptIntegrationTest < Minitest::Test
  UBUNTU = "PRETTY_NAME=\"Ubuntu 24.04 LTS\"\nNAME=\"Ubuntu\"\nID=ubuntu\nVERSION_CODENAME=noble\n"

  WINEHQ_SOURCE = {
    "key" => "https://dl.winehq.org/wine-builds/winehq.key",
    "keyring" => "/etc/apt/keyrings/winehq-archive.key",
    "sources" => "https://dl.winehq.org/wine-builds/ubuntu/dists/%{codename}/winehq-%{codename}.sources",
  }.freeze

  def setup
    @dir = Dir.mktmpdir("apt-integration-test-")
    @bin = File.join(@dir, "bin")
    FileUtils.mkdir_p(@bin)
    @out = StringIO.new
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def install(name)
    path = File.join(@bin, name)
    File.write(path, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, path)
  end

  def dep(name, **metadata)
    Dev::Deps::Dependency.new(
      name: name, integration: :apt, group: :build, version: "suite", hash: nil,
      metadata: metadata.transform_keys(&:to_s).merge("host" => "linux"),
    )
  end

  def winehq = dep("winehq-stable", source: WINEHQ_SOURCE, architectures: ["i386"], recommends: true)
  def xvfb = dep("xvfb")

  def integration(executor:, linux: true, tty: true, os_release: UBUNTU)
    os_release_path = File.join(@dir, "os-release")
    File.write(os_release_path, os_release)
    host = Dev::DebianHost.new(executor: executor, path: @bin, os_release_path: os_release_path)
    steps = Dev::PrivilegedSteps.new(executor: executor, tty: tty, purpose: "install declared apt packages")
    Dev::Deps::AptIntegration.new(
      repository: Dev::Deps::AptRepository.new, store: nil,
      executor: executor, host: host, steps: steps, linux: linux, root: @dir, out: @out,
    )
  end

  # Mark a source as converged on disk: its keyring and its sources file.
  def converge_source_on_disk(keyring: "/etc/apt/keyrings/winehq-archive.key",
    sources: "/etc/apt/sources.list.d/winehq-stable.sources")
    [keyring, sources].each do |path|
      full = File.join(@dir, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, "x")
    end
  end

  test "a converged host: probes only, no sudo, and the installed versions are reported" do
    Given "WineHQ and xvfb installed, i386 enabled, the source on disk"
    install("apt-get")
    converge_source_on_disk
    executor = RecordedAptExecutor.new(
      installed: { "winehq-stable" => "11.0.0.0~noble-1", "xvfb" => "2:21.1.12-1ubuntu1" }, foreign_archs: ["i386"],
    )

    When "installing"
    integration(executor: executor).install_all([winehq, xvfb])

    Then "nothing ran under sudo; each package's host version is in the summary"
    executor.sudo_runs.empty?
    @out.string.include?("winehq-stable 11.0.0.0~noble-1")
    @out.string.include?("xvfb 2:21.1.12-1ubuntu1")

    Cleanup
    nil
  end

  test "nothing present: one sudo session, then arch, source, update, install — each its own argv" do
    Given "a fresh Ubuntu noble host with a terminal"
    install("apt-get")
    executor = RecordedAptExecutor.new

    When "installing WineHQ (recommends) and xvfb (default)"
    integration(executor: executor).install_all([winehq, xvfb])

    Then "the steps, in order, with the codename interpolated and the key where the .sources expects it"
    executor.sudo_runs == [
      %w[sudo -v],
      %w[sudo dpkg --add-architecture i386],
      %w[sudo install -m 0755 -d /etc/apt/keyrings],
      %w[sudo curl -fsSL https://dl.winehq.org/wine-builds/winehq.key -o /etc/apt/keyrings/winehq-archive.key],
      %w[sudo chmod a+r /etc/apt/keyrings/winehq-archive.key],
      %w[sudo curl -fsSL https://dl.winehq.org/wine-builds/ubuntu/dists/noble/winehq-noble.sources
         -o /etc/apt/sources.list.d/winehq-stable.sources],
      %w[sudo apt-get update],
      %w[sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --install-recommends winehq-stable],
      %w[sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y xvfb],
    ]

    Cleanup
    nil
  end

  test "only the package missing: no arch or source steps, still update before install" do
    Given "source and arch converged, WineHQ not installed"
    install("apt-get")
    converge_source_on_disk
    executor = RecordedAptExecutor.new(foreign_archs: ["i386"])

    When "installing"
    integration(executor: executor).install_all([winehq])

    Then
    executor.sudo_runs == [
      %w[sudo -v],
      %w[sudo apt-get update],
      %w[sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --install-recommends winehq-stable],
    ]

    Cleanup
    nil
  end

  test "a one-line deb: source is written from a staged copy with %{arch}, %{codename} and %{keyring} filled" do
    Given "a package whose source is a deb line"
    install("apt-get")
    executor = RecordedAptExecutor.new(installed: { "docker-ce" => "5:28.0.1-1~ubuntu.24.04~noble" })
    docker = dep("docker-ce", source: {
      "key" => "https://download.docker.com/linux/ubuntu/gpg",
      "deb" => "deb [arch=%{arch} signed-by=%{keyring}] https://download.docker.com/linux/ubuntu %{codename} stable",
    })

    When "installing"
    integration(executor: executor).install_all([docker])

    Then "the key lands at the default keyring path; the .list holds the filled line"
    executor.sudo_runs.values_at(0, 1, 2, 3, 5) == [
      %w[sudo -v],
      %w[sudo install -m 0755 -d /etc/apt/keyrings],
      %w[sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker-ce.key],
      %w[sudo chmod a+r /etc/apt/keyrings/docker-ce.key],
      %w[sudo apt-get update],
    ]
    executor.sudo_runs[4].values_at(0, 1, 2, 3, 5) == %w[sudo install -m 0644 /etc/apt/sources.list.d/docker-ce.list]
    File.read(executor.sudo_runs[4][4]) ==
      "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker-ce.key] https://download.docker.com/linux/ubuntu noble stable\n"
    executor.sudo_runs.size == 6

    Cleanup
    nil
  end

  test "a deb: source whose line changed on disk is rewritten" do
    Given "the .list present with a stale line"
    install("apt-get")
    converge_source_on_disk(keyring: "/etc/apt/keyrings/docker-ce.key", sources: "/etc/apt/sources.list.d/docker-ce.list")
    executor = RecordedAptExecutor.new(installed: { "docker-ce" => "1" })
    docker = dep("docker-ce", source: { "key" => "https://d.com/gpg", "deb" => "deb https://d.com %{codename} stable" })

    When "installing"
    integration(executor: executor).install_all([docker])

    Then "only the sources file is rewritten (the key is already there), then update"
    executor.sudo_runs.size == 3
    executor.sudo_runs[1].values_at(0, 1, 2, 3, 5) == %w[sudo install -m 0644 /etc/apt/sources.list.d/docker-ce.list]
    executor.sudo_runs.last == %w[sudo apt-get update]

    Cleanup
    nil
  end

  test "two packages sharing one source converge it once" do
    Given "two packages from the same third-party source"
    install("apt-get")
    executor = RecordedAptExecutor.new
    a = dep("winehq-stable", source: WINEHQ_SOURCE)
    b = dep("wine-stable", source: WINEHQ_SOURCE)

    When "installing"
    integration(executor: executor).install_all([a, b])
    curls = executor.sudo_runs.map { |_sudo, bin, *_rest| bin }.tally.fetch("curl", 0)

    Then "one key fetch, one sources fetch, one install"
    curls == 2
    executor.sudo_runs.last == %w[sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y winehq-stable wine-stable]

    Cleanup
    nil
  end

  test "headless with passwordless sudo installs unattended" do
    Given "no terminal (a hosted runner) and sudo -n -v passing"
    install("apt-get")
    executor = RecordedAptExecutor.new

    When "installing"
    integration(executor: executor, tty: false).install_all([xvfb])

    Then
    executor.sudo_runs.first == %w[sudo -n -v]
    executor.sudo_runs.last == %w[sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y xvfb]

    Cleanup
    nil
  end

  test "headless on a host that would prompt fails at once, naming the one interactive dev up" do
    Given "no terminal and sudo wanting a password"
    install("apt-get")
    executor = RecordedAptExecutor.new(failing: "sudo -n -v")

    When "installing"
    error = assert_raises(Dev::PrivilegedSteps::SudoRequiredError) do
      integration(executor: executor, tty: false).install_all([xvfb])
    end

    Then
    error.message.include?("dev up")
    executor.sudo_runs == [%w[sudo -n -v]]

    Cleanup
    nil
  end

  test "a converged headless host never touches sudo at all" do
    Given "no terminal, everything installed"
    install("apt-get")
    executor = RecordedAptExecutor.new(installed: { "xvfb" => "1" })

    When "installing"
    integration(executor: executor, tty: false).install_all([xvfb])

    Then
    executor.sudo_runs.empty?

    Cleanup
    nil
  end

  test "no apt-get: refuse with the package list, before any sudo" do
    Given "a Linux without apt-get"
    executor = RecordedAptExecutor.new

    When "installing"
    error = assert_raises(Dev::Deps::AptIntegration::UnsupportedDistroError) do
      integration(executor: executor, os_release: "ID=fedora\nVERSION_CODENAME=\n").install_all([winehq, xvfb])
    end

    Then
    error.message.include?("fedora")
    error.message.include?("winehq-stable, xvfb")
    executor.sudo_runs.empty?

    Cleanup
    nil
  end

  test "a non-Linux host skips with a line" do
    Given "a Mac"
    executor = RecordedAptExecutor.new

    When "installing"
    integration(executor: executor, linux: false).install_all([winehq])

    Then
    executor.runs.empty?
    @out.string.include?("not a Linux host")

    Cleanup
    nil
  end

  test "a failing step raises StepFailedError naming it, and stops there" do
    Given "apt-get update failing"
    install("apt-get")
    executor = RecordedAptExecutor.new(failing: "apt-get update")

    When "installing"
    error = assert_raises(Dev::PrivilegedSteps::StepFailedError) { integration(executor: executor).install_all([xvfb]) }

    Then
    error.message.include?("sudo apt-get update")
    executor.sudo_runs.last == %w[sudo apt-get update]

    Cleanup
    nil
  end
end

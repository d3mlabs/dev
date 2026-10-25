# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/linux_data_root_provisioner"
require "dev/privileged_steps"
require "fileutils"
require "stringio"
require "tmpdir"

# Records every invocation; sudo is the true boundary. Creating the root
# is the one step whose effect the migration needs, so it is performed.
class RootCreatingSudoExecutor
  attr_reader :runs

  def initialize(root)
    @root = root
    @runs = []
  end

  def run(*cmd)
    @runs << cmd
    FileUtils.mkdir_p(@root) if cmd.first(2) == %w[sudo install]
    true
  end
end unless defined?(RootCreatingSudoExecutor)

transform!(RSpock::AST::Transformation)
class Dev::LinuxDataRootProvisionerTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("linux-root")
    @root = File.join(@dir, "var-lib-dev")
    @home_dev = File.join(@dir, "home-dev")
    @executor = RootCreatingSudoExecutor.new(@root)
    @out = StringIO.new
  end

  def teardown
    FileUtils.rm_rf(@dir)
    super
  end

  test "an absent root is created as root, handed to the user at 0755, and ~/.dev moved into it — one sudo session" do
    Given "a per-user root carrying an engine tree and state"
    FileUtils.mkdir_p(File.join(@home_dev, "engines", "ue5"))
    FileUtils.mkdir_p(File.join(@home_dev, "state"))

    When
    provisioner.provision!

    Then "the session, then exactly one privileged step, as its own argv"
    @executor.runs == [
      %w[sudo -v],
      ["sudo", "install", "-d", "-o", "jp", "-g", "staff", "-m", "0755", @root],
    ]
    File.directory?(File.join(@root, "engines", "ue5"))
    File.directory?(File.join(@home_dev, "state"))
    @out.string.include?(">>> Creating the data root #{@root} (one sudo prompt) ...")
  end

  test "a present, writable root is the steady state: no sudo, nothing moved" do
    Given
    FileUtils.mkdir_p(@root)
    FileUtils.mkdir_p(File.join(@home_dev, "engines"))

    When
    provisioner.provision!

    Then
    @executor.runs.empty?
    File.directory?(File.join(@home_dev, "engines"))
    @out.string.empty?
  end

  test "a present root this user cannot write is another identity's: named with the command, never re-owned" do
    Given
    FileUtils.mkdir_p(@root)
    File.chmod(0o555, @root)
    error = assert_raises(Dev::LinuxDataRootProvisioner::NotWritableError) { provisioner.provision! }

    Expect
    error.message.include?("#{@root} exists but jp cannot write it")
    error.message.include?("sudo chown -R jp:staff #{@root}")
    @executor.runs.empty?

    Cleanup
    File.chmod(0o755, @root)
  end

  test "status probes without root" do
    Given
    FileUtils.mkdir_p(@root)

    Expect
    provisioner.status.present
    provisioner.status.writable
    !Dev::LinuxDataRootProvisioner.new(steps: steps, root: File.join(@dir, "absent"), home_dev: @home_dev, user: "jp", group: "staff", out: @out).status.present
    @executor.runs.empty?
  end

  test "headless without passwordless sudo, the step is refused before anything is created" do
    Given "no terminal, and sudo -n -v fails"
    executor = RecordingFailingExecutor.new
    steps = Dev::PrivilegedSteps.new(executor: executor, tty: false, purpose: "create the data root")
    provisioner = Dev::LinuxDataRootProvisioner.new(steps: steps, root: @root, home_dev: @home_dev, user: "jp", group: "staff", out: @out)
    error = assert_raises(Dev::PrivilegedSteps::SudoRequiredError) { provisioner.provision! }

    Expect
    error.message.include?("dev needs root to create the data root")
    !File.exist?(@root)
  end

  test "for_host applies on Linux with the default root only: #{what}" do
    Expect
    Dev::LinuxDataRootProvisioner.for_host(env: env, host_os: host_os).nil? == none

    Where
    what                        | env                                | host_os  | none
    "a Linux host"              | {}                                 | "linux"  | false
    "a Mac"                     | {}                                 | "darwin" | true
    "Linux with DEV_DATA_ROOT"  | { "DEV_DATA_ROOT" => "/mnt/dev" }  | "linux"  | true
    "Linux with it blank"       | { "DEV_DATA_ROOT" => "" }          | "linux"  | false
  end

  private

  def steps
    Dev::PrivilegedSteps.new(executor: @executor, tty: true, purpose: "create the data root")
  end

  def provisioner
    Dev::LinuxDataRootProvisioner.new(steps: steps, root: @root, home_dev: @home_dev, user: "jp", group: "staff", out: @out)
  end
end

# Every command fails and is recorded.
class RecordingFailingExecutor
  attr_reader :runs

  def initialize
    @runs = []
  end

  def run(*cmd)
    @runs << cmd
    false
  end
end unless defined?(RecordingFailingExecutor)

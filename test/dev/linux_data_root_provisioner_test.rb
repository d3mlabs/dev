# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/linux_data_root_provisioner"
require "dev/privileged_steps"
require "etc"
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

  test "an absent root is created as root, owned by the user, group-shared at 2775, and ~/.dev moved into it — one sudo session" do
    Given "a per-user root carrying an engine tree and state"
    FileUtils.mkdir_p(File.join(@home_dev, "engines", "ue5"))
    FileUtils.mkdir_p(File.join(@home_dev, "state"))

    When
    provisioner.provision!

    Then "the session, the group and the membership, then the root — each its own argv"
    @executor.runs == [
      %w[sudo -v],
      %w[sudo groupadd -f dev],
      %w[sudo usermod -aG dev jp],
      ["sudo", "install", "-d", "-o", "jp", "-g", "dev", "-m", "2775", @root],
    ]
    File.directory?(File.join(@root, "engines", "ue5"))
    File.directory?(File.join(@home_dev, "state"))
    @out.string.include?(">>> Creating the data root #{@root}, shared with group dev (one sudo prompt) ...")
    @out.string.include?("jp is in group dev from the next login")
  end

  test "a present, writable, group-shared root is the steady state: no sudo, nothing moved" do
    Given "a root already in this user's group at 2775"
    FileUtils.mkdir_p(@root)
    File.chmod(0o2775, @root)
    FileUtils.mkdir_p(File.join(@home_dev, "engines"))

    When
    provisioner(group: own_group).provision!

    Then
    @executor.runs.empty?
    File.directory?(File.join(@home_dev, "engines"))
    @out.string.empty?
  end

  test "a present, writable root not yet shared (the single-owner 0755 of dev#308) is converged in place: group and mode, never owner" do
    Given "a single-owner root with a tree and a per-uid secrets dir"
    FileUtils.mkdir_p(File.join(@root, "store"))
    FileUtils.mkdir_p(File.join(@root, "secrets-1000"))
    File.chmod(0o755, @root)

    When
    provisioner.provision!

    Then "group, root mode, then the tree — secrets dirs pruned — with no chown anywhere"
    @executor.runs == [
      %w[sudo -v],
      %w[sudo groupadd -f dev],
      %w[sudo usermod -aG dev jp],
      ["sudo", "chgrp", "-Rh", "dev", @root],
      ["sudo", *Dev::LinuxDataRootProvisioner.share_tree_argv(@root)],
    ]
    @executor.runs.none? { |cmd| cmd.include?("chown") }
    @out.string.include?(">>> Sharing the data root #{@root} with group dev (one sudo prompt) ...")
    @out.string.include?("jp is in group dev from the next login")
  end

  test "the tree walk opens dirs and files to the group, prunes secrets dirs, and steps over symlinks — a dangling one (a fetched tree's link into a mod) does not fail it" do
    Given "a real tree: a dir with a file, a secrets dir, a dangling symlink and a live one"
    FileUtils.mkdir_p(File.join(@root, "gh", "tree"))
    File.write(File.join(@root, "gh", "tree", "file"), "x")
    FileUtils.mkdir_p(File.join(@root, "secrets-1000"))
    File.write(File.join(@root, "secrets-1000", "token"), "t")
    File.symlink("/nonexistent/Mods/Snappy", File.join(@root, "gh", "tree", "Snappy"))
    File.symlink(File.join(@root, "gh", "tree", "file"), File.join(@root, "gh", "tree", "alias"))
    File.chmod(0o755, @root)
    File.chmod(0o755, File.join(@root, "gh"))
    File.chmod(0o755, File.join(@root, "gh", "tree"))
    File.chmod(0o644, File.join(@root, "gh", "tree", "file"))
    File.chmod(0o700, File.join(@root, "secrets-1000"))
    File.chmod(0o600, File.join(@root, "secrets-1000", "token"))

    When "the walk runs for real, as this user"
    ok = system(*Dev::LinuxDataRootProvisioner.share_tree_argv(@root), err: File::NULL)

    Then "it succeeds; dirs are g+rwxs, files g+rw, secrets untouched, the live link's target widened once by its own path"
    ok
    (File.stat(File.join(@root, "gh", "tree")).mode & 0o2070) == 0o2070
    (File.stat(File.join(@root, "gh", "tree", "file")).mode & 0o070) == 0o060
    (File.stat(File.join(@root, "secrets-1000")).mode & 0o777) == 0o700
    (File.stat(File.join(@root, "secrets-1000", "token")).mode & 0o777) == 0o600
    File.lstat(File.join(@root, "gh", "tree", "Snappy")).symlink?
  end

  test "a present root this user cannot write is another identity's: the group fix is named, never a chown" do
    Given
    FileUtils.mkdir_p(@root)
    File.chmod(0o555, @root)
    error = assert_raises(Dev::LinuxDataRootProvisioner::NotWritableError) { provisioner.provision! }

    Expect
    error.message.include?("#{@root} exists but jp cannot write it")
    error.message.include?("sudo usermod -aG dev jp")
    error.message.include?("log in again")
    error.message.include?("its owner's `dev up` shares it")
    !error.message.include?("chown")
    @executor.runs.empty?

    Cleanup
    File.chmod(0o755, @root)
  end

  test "status probes without root: present, writable, and whether the root is shared with the group — #{what}" do
    Given
    FileUtils.mkdir_p(@root)
    File.chmod(mode, @root)
    group = own ? own_group : "dev-nope"

    Expect
    provisioner(group: group).status.present
    provisioner(group: group).status.writable
    provisioner(group: group).status.shared == shared
    !Dev::LinuxDataRootProvisioner.new(steps: steps, root: File.join(@dir, "absent"), home_dev: @home_dev, user: "jp", group: "dev", out: @out).status.present
    @executor.runs.empty?

    Where
    what                              | own    | mode    | shared
    "the group at 2775"               | true   | 0o2775  | true
    "the group without setgid"        | true   | 0o775   | false
    "the group without group write"   | true   | 0o2755  | false
    "another group at 2775"           | false  | 0o2775  | false
  end

  test "a root whose gid the group database does not know is not shared" do
    Given "a root at 2775 whose gid names no group (the group database is the boundary)"
    FileUtils.mkdir_p(@root)
    File.chmod(0o2775, @root)
    Etc.stubs(:getgrgid).raises(ArgumentError, "can't find group for 65534")

    Expect
    provisioner.status.writable
    !provisioner.status.shared
    @executor.runs.empty?
  end

  test "headless without passwordless sudo, the step is refused before anything is created" do
    Given "no terminal, and sudo -n -v fails"
    executor = RecordingFailingExecutor.new
    steps = Dev::PrivilegedSteps.new(executor: executor, tty: false, purpose: "create the data root")
    provisioner = Dev::LinuxDataRootProvisioner.new(steps: steps, root: @root, home_dev: @home_dev, user: "jp", group: "dev", out: @out)
    error = assert_raises(Dev::PrivilegedSteps::SudoRequiredError) { provisioner.provision! }

    Expect
    error.message.include?("dev needs root to create the data root")
    !File.exist?(@root)
  end

  test "the shared group is dev by default" do
    Expect
    Dev::LinuxDataRootProvisioner::GROUP == "dev"
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

  # The group the test's own directories carry: the one name a tmpdir can
  # be "shared with" without root.
  def own_group
    Etc.getgrgid(File.stat(@dir).gid).name
  end

  def steps
    Dev::PrivilegedSteps.new(executor: @executor, tty: true, purpose: "create the data root")
  end

  def provisioner(group: "dev")
    Dev::LinuxDataRootProvisioner.new(steps: steps, root: @root, home_dev: @home_dev, user: "jp", group: group, out: @out)
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

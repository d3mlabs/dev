# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/debian_host"
require "tmpdir"
require "fileutils"

# dpkg is the one boundary a host fact needs a process for.
class RecordedDpkgExecutor
  attr_reader :runs

  def initialize(arch: "amd64")
    @arch = arch
    @runs = []
  end

  def capture(*cmd)
    @runs << cmd
    cmd == %w[dpkg --print-architecture] ? "#{@arch}\n" : ""
  end
end unless defined?(RecordedDpkgExecutor)

transform!(RSpock::AST::Transformation)
class Dev::DebianHostTest < Minitest::Test
  UBUNTU = "PRETTY_NAME=\"Ubuntu 24.04 LTS\"\nNAME=\"Ubuntu\"\nID=ubuntu\nVERSION_CODENAME=noble\n"

  def setup
    @dir = Dir.mktmpdir("debian-host-test-")
    @bin = File.join(@dir, "bin")
    FileUtils.mkdir_p(@bin)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def install(name)
    path = File.join(@bin, name)
    File.write(path, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, path)
    path
  end

  def host(os_release: UBUNTU, executor: RecordedDpkgExecutor.new)
    os_release_path = File.join(@dir, "os-release")
    File.write(os_release_path, os_release) if os_release
    Dev::DebianHost.new(executor: executor, path: @bin, os_release_path: os_release_path)
  end

  test "reads the distro id and codename from os-release, unquoted" do
    Given "an Ubuntu noble os-release"
    h = host

    Expect
    h.distro_id == "ubuntu"
    h.codename == "noble"
  end

  test "an unreadable os-release answers unknown / stable rather than raising" do
    Given "no os-release file"
    h = host(os_release: nil)

    Expect
    h.distro_id == "unknown"
    h.codename == "stable"
  end

  test "apt_get? is whether apt-get is on PATH; which finds executables only" do
    Given "apt-get on the PATH dir and a non-executable file beside it"
    install("apt-get")
    File.write(File.join(@bin, "notes"), "x")
    h = host

    Expect
    h.apt_get? == true
    h.which("apt-get") == File.join(@bin, "apt-get")
    h.which("notes").nil?
    h.which("missing").nil?
  end

  test "arch asks dpkg once" do
    Given "a dpkg that answers amd64"
    executor = RecordedDpkgExecutor.new(arch: "amd64")
    h = host(executor: executor)

    Expect
    h.arch == "amd64"
    executor.runs == [%w[dpkg --print-architecture]]
  end
end

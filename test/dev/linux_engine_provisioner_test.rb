# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/linux_engine_provisioner"
require "stringio"
require "tmpdir"
require "fileutils"

# Records every invocation; systemctl, docker, id, dpkg, and sudo are true
# boundaries. The machine it describes: whether dockerd is active, whether
# buildx answers, which groups the user has, which containers run, and which
# streamed command (if any) fails.
class RecordedLinuxExecutor
  attr_reader :runs

  def initialize(dockerd_active: true, buildx: true, groups: %w[jpduchesne docker], containers: [], arch: "amd64",
    failing: nil)
    @dockerd_active = dockerd_active
    @buildx = buildx
    @groups = groups
    @containers = containers
    @arch = arch
    @failing = failing
    @runs = []
  end

  def run(*cmd)
    @runs << cmd
    @failing.nil? || !cmd.join(" ").include?(@failing)
  end

  def quiet?(*cmd)
    @runs << cmd
    case cmd
    when ["systemctl", "is-active", "--quiet", "docker"] then @dockerd_active
    when ["docker", "buildx", "version"] then @buildx
    else true
    end
  end

  def capture(*cmd)
    @runs << cmd
    case cmd
    when ["id", "-nG", "jpduchesne"] then "#{@groups.join(" ")}\n"
    when ["dpkg", "--print-architecture"] then "#{@arch}\n"
    when ["docker", "ps", "--format", "{{.Names}}"] then @containers.map { |name| "#{name}\n" }.join
    else ""
    end
  end

  def sudo_runs
    @runs.select { |bin, *_rest| bin == "sudo" }
  end
end unless defined?(RecordedLinuxExecutor)

transform!(RSpock::AST::Transformation)
class Dev::LinuxEngineProvisionerTest < Minitest::Test
  UBUNTU = "PRETTY_NAME=\"Ubuntu 26.04 LTS\"\nNAME=\"Ubuntu\"\nID=ubuntu\nVERSION_CODENAME=resolute\n"
  SYSTEMD_ON = "[boot]\nsystemd=true\n"

  def setup
    @dir = Dir.mktmpdir("linux-engine-test-")
    @bin = File.join(@dir, "bin")
    FileUtils.mkdir_p(@bin)
    @out = StringIO.new
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  # Drop a fake executable named +name+ into +dir+ (default: the PATH dir).
  def install(name, dir: @bin)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, name)
    File.write(path, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, path)
    path
  end

  def provisioner(executor: RecordedLinuxExecutor.new, wsl: false, os_release: UBUNTU, wsl_conf: SYSTEMD_ON,
    extra_path: [])
    os_release_path = File.join(@dir, "os-release")
    File.write(os_release_path, os_release) if os_release
    wsl_conf_path = File.join(@dir, "wsl.conf")
    File.write(wsl_conf_path, wsl_conf) if wsl_conf
    Dev::LinuxEngineProvisioner.new(
      executor: executor, wsl: wsl, user: "jpduchesne", out: @out,
      path: ([@bin] + extra_path).join(File::PATH_SEPARATOR),
      os_release_path: os_release_path, wsl_conf_path: wsl_conf_path,
    )
  end

  test "a converged bare-Linux box: probes only, no sudo" do
    Given "docker-ce installed and active, buildx present, user in the group"
    install("docker")
    install("apt-get")
    executor = RecordedLinuxExecutor.new
    prov = provisioner(executor: executor)

    When "provisioning"
    prov.provision!

    Then "nothing was run as root and nothing was printed"
    executor.sudo_runs.empty?
    @out.string.empty?

    Cleanup
    nil
  end

  test "Docker Desktop's WSL shim owns docker: refuse before any install" do
    Given "docker resolving to Desktop's cli-tools mount"
    shim_dir = File.join(@dir, "mnt", "wsl", "docker-desktop", "cli-tools", "usr", "bin")
    install("docker", dir: shim_dir)
    install("apt-get")
    executor = RecordedLinuxExecutor.new(dockerd_active: false)
    prov = provisioner(executor: executor, wsl: true, extra_path: [shim_dir])

    When "provisioning"
    error = assert_raises(Dev::LinuxEngineProvisioner::DesktopIntegrationError) { prov.provision! }

    Then "the message says how to hand the distro back, and no sudo ran"
    error.message.include?("WSL integration")
    error.message.include?(File.join(shim_dir, "docker"))
    executor.sudo_runs.empty?

    Cleanup
    nil
  end

  test "Desktop's shim is detected through the /usr/bin/docker symlink its integration installs" do
    Given "docker on PATH as a symlink into Desktop's cli-tools mount — the gamebox's actual layout"
    shim_dir = File.join(@dir, "mnt", "wsl", "docker-desktop", "cli-tools", "usr", "bin")
    shim = install("docker", dir: shim_dir)
    File.symlink(shim, File.join(@bin, "docker"))
    install("apt-get")
    executor = RecordedLinuxExecutor.new(dockerd_active: false)
    prov = provisioner(executor: executor, wsl: true)

    When "provisioning"
    error = assert_raises(Dev::LinuxEngineProvisioner::DesktopIntegrationError) { prov.provision! }

    Then "the refusal names both the link and its target, and status says shim"
    error.message.include?(File.join(@bin, "docker"))
    error.message.include?(shim)
    prov.status.desktop_shim == true
    executor.sudo_runs.empty?

    Cleanup
    nil
  end

  test "nothing installed on Ubuntu: one sudo credential prompt, then the exact install steps" do
    Given "a fresh WSL Ubuntu with systemd already on, docker absent, user not yet in the group"
    install("apt-get")
    executor = RecordedLinuxExecutor.new(dockerd_active: false, buildx: false, groups: %w[jpduchesne sudo])
    prov = provisioner(executor: executor, wsl: true)

    When "provisioning"
    error = assert_raises(Dev::LinuxEngineProvisioner::RestartRequiredError) { prov.provision! }

    Then "the steps run in order under sudo, and the new group membership needs a fresh login"
    executor.sudo_runs == [
      %w[sudo -v],
      %w[sudo install -m 0755 -d /etc/apt/keyrings],
      %w[sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc],
      %w[sudo chmod a+r /etc/apt/keyrings/docker.asc],
      [
        "sudo", "sh", "-c",
        "echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] " \
        "https://download.docker.com/linux/ubuntu resolute stable' > /etc/apt/sources.list.d/docker.list",
      ],
      %w[sudo apt-get update],
      %w[sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin],
      %w[sudo systemctl enable --now docker],
      %w[sudo usermod -aG docker jpduchesne],
    ]
    error.message.include?("docker group")
    error.message.include?("dev up")
    !error.message.include?("wsl --shutdown")

    Cleanup
    nil
  end

  test "installed but stopped, user already in the group: only the enable step" do
    Given "docker-ce present, daemon not running"
    install("docker")
    install("apt-get")
    executor = RecordedLinuxExecutor.new(dockerd_active: false)
    prov = provisioner(executor: executor)

    When "provisioning"
    prov.provision!

    Then "one prompt, one step, no restart"
    executor.sudo_runs == [%w[sudo -v], %w[sudo systemctl enable --now docker]]

    Cleanup
    nil
  end

  test "WSL without systemd in /etc/wsl.conf: writes it and asks for the VM restart" do
    Given "a converged daemon on a distro whose wsl.conf lacks [boot] systemd"
    install("docker")
    install("apt-get")
    executor = RecordedLinuxExecutor.new
    prov = provisioner(executor: executor, wsl: true, wsl_conf: wsl_conf)

    When "provisioning"
    error = assert_raises(Dev::LinuxEngineProvisioner::RestartRequiredError) { prov.provision! }

    Then "a staged copy is installed over /etc/wsl.conf under sudo, and the message names wsl --shutdown"
    executor.sudo_runs.size == 2
    executor.sudo_runs.first == %w[sudo -v]
    executor.sudo_runs.last.values_at(0, 1, 2, 3, 5) == ["sudo", "install", "-m", "0644", File.join(@dir, "wsl.conf")]
    File.read(executor.sudo_runs.last[4]) == staged
    error.message.include?("wsl --shutdown")

    Cleanup
    nil

    Where
    wsl_conf                      | staged
    nil                           | "[boot]\nsystemd=true\n"
    ""                            | "[boot]\nsystemd=true\n"
    "[automount]\nenabled=true\n" | "[automount]\nenabled=true\n\n[boot]\nsystemd=true\n"
    "[boot]\nsystemd=false\n"     | "[boot]\nsystemd=true\n"
    "[boot]\ncommand=foo\n"       | "[boot]\ncommand=foo\nsystemd=true\n"
  end

  test "WSL with systemd spelled differently still counts" do
    Given "a wsl.conf with spaces and capitals"
    install("docker")
    install("apt-get")
    executor = RecordedLinuxExecutor.new
    prov = provisioner(executor: executor, wsl: true, wsl_conf: "[Boot]\nSystemd = True\n")

    When "provisioning"
    prov.provision!

    Then "nothing to do"
    executor.sudo_runs.empty?

    Cleanup
    nil
  end

  test "no apt-get: refuse with the distro's own instructions, no sudo" do
    Given "a non-Debian distro without docker"
    executor = RecordedLinuxExecutor.new(dockerd_active: false, buildx: false)
    prov = provisioner(executor: executor, os_release: "ID=fedora\nVERSION_ID=42\n")

    When "provisioning"
    error = assert_raises(Dev::LinuxEngineProvisioner::UnsupportedDistroError) { prov.provision! }

    Then "the message names the distro and the packages, and nothing ran as root"
    error.message.include?("fedora")
    error.message.include?("docker-buildx-plugin")
    executor.sudo_runs.empty?

    Cleanup
    nil
  end

  test "a failing step raises StepFailedError naming it, and stops there" do
    Given "an apt-get update that fails"
    install("apt-get")
    executor = RecordedLinuxExecutor.new(dockerd_active: false, buildx: false, failing: "apt-get update")
    prov = provisioner(executor: executor)

    When "provisioning"
    error = assert_raises(Dev::LinuxEngineProvisioner::StepFailedError) { prov.provision! }

    Then "the message carries the argv and no later step ran"
    error.message.include?("sudo apt-get update")
    executor.sudo_runs.last == %w[sudo apt-get update]

    Cleanup
    nil
  end

  test "a declined sudo prompt is a failed step too" do
    Given "sudo -v failing"
    install("apt-get")
    executor = RecordedLinuxExecutor.new(dockerd_active: false, failing: "sudo -v")
    prov = provisioner(executor: executor)

    When "provisioning"
    error = assert_raises(Dev::LinuxEngineProvisioner::StepFailedError) { prov.provision! }

    Then "nothing else was attempted"
    error.message.include?("sudo -v")
    executor.sudo_runs == [%w[sudo -v]]

    Cleanup
    nil
  end

  test "stop! stops dockerd whatever is running in it — busy-ness is the caller's decision" do
    Given "a daemon with a container running"
    install("docker")
    executor = RecordedLinuxExecutor.new(containers: %w[snappy-build])
    prov = provisioner(executor: executor)

    When "stopping"
    prov.stop!

    Then "the sudo credential is primed, then dockerd is stopped; no container is touched"
    executor.runs.select { |bin, sub, *_rest| %w[sudo docker].include?(bin) && sub != "ps" } ==
      [%w[sudo -v], %w[sudo systemctl stop docker]]

    Cleanup
    nil
  end

  test "status reports the daemon facts" do
    Given "an installed, active daemon with buildx and group membership, on WSL with systemd"
    docker = install("docker")
    executor = RecordedLinuxExecutor.new
    prov = provisioner(executor: executor, wsl: true)

    When "asking"
    status = prov.status

    Then
    status.docker_path == docker
    status.desktop_shim == false
    status.dockerd_active == true
    status.buildx == true
    status.in_docker_group == true
    status.systemd_enabled == true
    status.converged?

    Cleanup
    nil
  end

  test "status on bare Linux has no systemd fact to report" do
    Given "no WSL"
    install("docker")
    prov = provisioner(executor: RecordedLinuxExecutor.new, wsl: false)

    Expect
    prov.status.systemd_enabled.nil?
    prov.status.converged?
  end
end

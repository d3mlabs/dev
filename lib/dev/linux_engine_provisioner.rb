# typed: strict
# frozen_string_literal: true

require "etc"
require "stringio"

require "dev/debian_host"
require "dev/ini_file"
require "dev/privileged_steps"
require "dev/process_executor"
require "dev/wsl_host"

module Dev
  # Idempotent converge of the one supported Linux engine: Docker's own
  # `docker-ce` as a rootful system service, with the invoking user in the
  # `docker` group. The Linux counterpart of ColimaProvisioner — brew delivers
  # colima on macOS, apt delivers dockerd here — and on WSL2 the engine of
  # the Windows story, since dev runs inside the distro.
  #
  # Probe first, prompt only when there is work: a converged box costs a few
  # read-only checks and no sudo. When something is missing, one `sudo -v`
  # asks for the password and the steps that follow ride the cached
  # credential, each as its own argv so a failure names what failed.
  #
  # Refusals come before any install, as typed errors with the way out:
  #
  # - DesktopIntegrationError: Docker Desktop's WSL-integration shim owns
  #   `docker` in this distro. It cannot be converged from inside the distro
  #   and would fight dpkg for /usr/bin/docker and the socket; the user unticks
  #   the distro under Desktop > Settings > Resources > WSL integration.
  # - UnsupportedDistroError: no apt-get. Only the Debian family is scripted;
  #   the message hands over the package list for the distro's own tool.
  #
  # RestartRequiredError when something written is not yet in effect: a new
  # `docker` group membership needs a fresh login; `systemd=true` in
  # /etc/wsl.conf needs the VM restarted. dev never runs `wsl --shutdown`
  # itself — it would kill its own session and every runner service.
  class LinuxEngineProvisioner
    extend T::Sig

    # Docker Desktop's shim provides `docker` here; converging would fight it.
    class DesktopIntegrationError < RuntimeError; end

    # No apt-get: the distro is not one dev knows how to install docker on.
    class UnsupportedDistroError < RuntimeError; end

    # A written change (group membership, wsl.conf) takes effect only after a
    # re-login or VM restart.
    class RestartRequiredError < RuntimeError; end

    # An admin step exited nonzero (PrivilegedSteps' error, under the name callers know).
    StepFailedError = PrivilegedSteps::StepFailedError

    # The daemon facts `dev engine status` renders for Linux/WSL.
    class Status < T::Struct
      extend T::Sig

      const :docker_path, T.nilable(String)
      const :desktop_shim, T::Boolean
      const :dockerd_active, T::Boolean
      const :buildx, T::Boolean
      const :in_docker_group, T::Boolean
      const :systemd_enabled, T.nilable(T::Boolean) # nil off WSL

      # Whether `provision!` would have nothing to do.
      #
      # @return [Boolean]
      sig { returns(T::Boolean) }
      def converged?
        !docker_path.nil? && !desktop_shim && dockerd_active && buildx && in_docker_group && systemd_enabled != false
      end
    end

    PACKAGES = T.let(%w[docker-ce docker-ce-cli containerd.io docker-buildx-plugin].freeze, T::Array[String])
    KEYRING = "/etc/apt/keyrings/docker.asc"
    SOURCES_LIST = "/etc/apt/sources.list.d/docker.list"
    DESKTOP_SHIM_MARKER = "/docker-desktop/"
    WSL_CONF = "/etc/wsl.conf"
    GROUP = "docker"

    # @param executor [#run, #quiet?, #capture] process seam; `run` streams so the sudo prompt reaches the TTY
    # @param wsl [Boolean] whether this Linux is a WSL2 distro (adds the wsl.conf systemd step)
    # @param user [String] the invoking user, who joins the docker group
    # @param out [IO, StringIO] progress lines
    # @param path [String] PATH to resolve `docker` and `apt-get` on
    # @param os_release_path [String] for the distro id and codename
    # @param wsl_conf_path [String] the distro's /etc/wsl.conf
    sig do
      params(
        executor: T.untyped,
        wsl: T::Boolean,
        user: String,
        out: T.any(IO, StringIO),
        path: String,
        os_release_path: String,
        wsl_conf_path: String,
      ).void
    end
    def initialize(executor: ProcessExecutor.new, wsl: WslHost.new.wsl?, user: T.must(Etc.getpwuid(Process.uid)).name,
      out: $stderr, path: ENV.fetch("PATH", ""), os_release_path: DebianHost::OS_RELEASE, wsl_conf_path: WSL_CONF)
      @executor = executor
      @wsl = wsl
      @user = user
      @out = out
      @wsl_conf_path = wsl_conf_path
      @host = T.let(DebianHost.new(executor: executor, path: path, os_release_path: os_release_path), DebianHost)
      @steps = T.let(PrivilegedSteps.new(executor: executor, tty: true, purpose: "converge dockerd"), PrivilegedSteps)
    end

    # @return [Status]
    sig { returns(Status) }
    def status
      docker = @host.which("docker")
      Status.new(
        docker_path: docker,
        desktop_shim: !docker.nil? && desktop_shim?(docker),
        dockerd_active: T.unsafe(@executor).quiet?("systemctl", "is-active", "--quiet", "docker"),
        buildx: !docker.nil? && T.unsafe(@executor).quiet?("docker", "buildx", "version"),
        in_docker_group: groups.include?(GROUP),
        systemd_enabled: @wsl ? systemd_enabled? : nil,
      )
    end

    # Converge dockerd for the invoking user. See the class doc.
    #
    # @return [void]
    # @raise [DesktopIntegrationError]
    # @raise [UnsupportedDistroError]
    # @raise [StepFailedError]
    # @raise [RestartRequiredError]
    sig { void }
    def provision!
      current = status
      if current.desktop_shim
        docker = T.must(current.docker_path)
        raise DesktopIntegrationError,
          "`docker` here is Docker Desktop's WSL-integration shim (#{docker} -> #{File.realpath(docker)}), which " \
          "owns the engine in this distro. dev cannot converge dockerd alongside it: in Docker Desktop > Settings > " \
          "Resources > WSL integration, untick this distro, open a new shell, and re-run `dev up`."
      end
      return if current.converged?

      install = current.docker_path.nil? || !current.buildx
      if install && !@host.apt_get?
        raise UnsupportedDistroError,
          "no apt-get on this #{@host.distro_id} box — dev only scripts the Docker install for the Debian family. " \
          "Install #{PACKAGES.join(", ")} with your distro's tool, enable the docker service, add #{@user} to the " \
          "#{GROUP} group, and re-run `dev up`."
      end

      @out.puts ">>> Converging dockerd (one sudo prompt) ..."
      @steps.session!
      install_packages! if install
      @steps.step!("sudo", "systemctl", "enable", "--now", "docker") if install || !current.dockerd_active
      @steps.step!("sudo", "usermod", "-aG", GROUP, @user) unless current.in_docker_group
      wsl_conf_needed = current.systemd_enabled == false
      @steps.install_file!(systemd_wsl_conf, @wsl_conf_path, mode: "0644") if wsl_conf_needed

      restart_hint(group_added: !current.in_docker_group, wsl_conf_written: wsl_conf_needed)
    end

    # Stop dockerd — the Linux/WSL "engine down". Never the WSL VM: dev lives
    # in it, and WSL hands idle memory back on its own (autoMemoryReclaim).
    # Whatever is running inside goes down with the daemon: whether that is
    # acceptable is the caller's decision (`dev engine down` stops dev's own
    # containers and asks about the user's first), not this primitive's.
    #
    # @return [void]
    # @raise [StepFailedError]
    sig { void }
    def stop!
      @steps.session!
      @steps.step!("sudo", "systemctl", "stop", "docker")
    end

    private

    # Docker's apt repository and packages, as Docker documents them.
    #
    # @return [void]
    # @raise [StepFailedError]
    sig { void }
    def install_packages!
      id = @host.distro_id
      @steps.step!("sudo", "install", "-m", "0755", "-d", File.dirname(KEYRING))
      @steps.step!("sudo", "curl", "-fsSL", "https://download.docker.com/linux/#{id}/gpg", "-o", KEYRING)
      @steps.step!("sudo", "chmod", "a+r", KEYRING)
      @steps.install_file!(
        "deb [arch=#{@host.arch} signed-by=#{KEYRING}] https://download.docker.com/linux/#{id} #{@host.codename} stable\n",
        SOURCES_LIST, mode: "0644",
      )
      @steps.step!("sudo", "apt-get", "update")
      @steps.step!(*T.unsafe(["sudo", "apt-get", "install", "-y", *PACKAGES]))
    end

    # @param group_added [Boolean]
    # @param wsl_conf_written [Boolean]
    # @return [void]
    # @raise [RestartRequiredError] when either change needs a restart to take effect
    sig { params(group_added: T::Boolean, wsl_conf_written: T::Boolean).void }
    def restart_hint(group_added:, wsl_conf_written:)
      if wsl_conf_written
        changes = ["systemd was enabled in #{@wsl_conf_path}"]
        changes << "#{@user} joined the #{GROUP} group" if group_added
        raise RestartRequiredError,
          "#{changes.join(" and ")}; this takes effect when the VM restarts. From Windows run `wsl --shutdown` " \
          "(this stops every WSL distro and the runner services in them), then `dev up` again."
      end
      return unless group_added

      raise RestartRequiredError,
        "#{@user} joined the #{GROUP} group; the membership applies to new logins. Log out and back in " \
        "(or `newgrp #{GROUP}` in this shell; runner services pick it up on " \
        "`sudo systemctl restart 'actions.runner.*'`), then `dev up` again."
    end

    # Whether +docker+ is Docker Desktop's WSL-integration shim. Desktop
    # installs it as a symlink (`/usr/bin/docker` → `/mnt/wsl/docker-desktop/
    # cli-tools/…`), so the resolved path is what carries the marker. `DebianHost#which`
    # only returns existing files, so the resolution cannot dangle.
    #
    # @param docker [String] the PATH entry `which` found
    # @return [Boolean]
    sig { params(docker: String).returns(T::Boolean) }
    def desktop_shim?(docker)
      File.realpath(docker).include?(DESKTOP_SHIM_MARKER)
    end

    # @return [Array<String>] the invoking user's groups
    sig { returns(T::Array[String]) }
    def groups
      T.unsafe(@executor).capture("id", "-nG", @user).split
    end

    # @return [Boolean] whether /etc/wsl.conf has `[boot] systemd=true`
    sig { returns(T::Boolean) }
    def systemd_enabled?
      wsl_conf.value("boot", "systemd").to_s.casecmp?("true")
    end

    # @return [IniFile] the distro's wsl.conf (empty when absent)
    sig { returns(IniFile) }
    def wsl_conf
      IniFile.parse(File.exist?(@wsl_conf_path) ? File.read(@wsl_conf_path) : "")
    end

    # @return [String] wsl.conf content with systemd enabled
    sig { returns(String) }
    def systemd_wsl_conf
      wsl_conf.set("boot", "systemd", "true").render
    end
  end
end

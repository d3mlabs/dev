# typed: strict
# frozen_string_literal: true

require "stringio"

require "dev/engine_resources"
require "dev/privileged_steps"
require "dev/process_executor"
require "dev/wsl_conf"
require "dev/wsl_host"
require "dev/wsl_keepalive_task"
require "dev/wsl_provisioner"

module Dev
  # The WSL runner host (dev#261): what a runner enrolled in a WSL2 distro
  # needs of the Windows side to survive a reboot, converged by `dev runner
  # register` before it enrolls and re-derived by `dev runner status`. The
  # same seam as the agent host bootstrap — host facts a label-less
  # enrollment still depends on — with different contract facts:
  #
  # - the **logon keepalive** (WslKeepaliveTask): a Task Scheduler task that
  #   boots the distro at logon and holds a client session, without which
  #   WSL stops the distro ~20 s after the last session ends and every
  #   systemd unit in it — the runner services first — goes down with it;
  # - **systemd** in `/etc/wsl.conf` (WslConf): the runner service is a
  #   systemd unit, so without `[boot] systemd=true` svc.sh has nothing to
  #   install into — `dev up` writes it for a containerized checkout
  #   (LinuxEngineProvisioner); here it is asserted for every enrollment;
  # - **`.wslconfig` sizing** (WslProvisioner): the engine step already
  #   ratchets it for a checkout that pins an image; here it runs for every
  #   WSL registration, hint or none, so a pending resize is said now, not
  #   assumed applied because `dev up` ran once.
  #
  # Everything Windows-side goes through interop (`powershell.exe`), which
  # only a login session has (WslHost#interop?): a service or an ssh login
  # cannot register the task, and register refuses rather than enroll a
  # runner that the next reboot takes down. The task is registered as the
  # logged-on user; when a prior one exists that was registered elevated
  # (the per-repo bootstrap scripts did), replacing it takes one UAC prompt
  # — the prompt-once posture of the Mac host steps. Writing `wsl.conf` is
  # PrivilegedSteps' sudo contract, like every root write on a Linux host.
  # dev never runs `wsl --shutdown`: it lives in the VM it would stop.
  class WslRunnerHost
    extend T::Sig

    # The Windows side cannot be reached from this session, so the keepalive
    # can neither be read nor registered.
    class InteropRequiredError < RuntimeError; end

    # systemd is enabled in `/etc/wsl.conf` but not running: the distro has
    # to be restarted before a runner service can be installed.
    class RestartRequiredError < RuntimeError; end

    # A PowerShell step exited nonzero.
    class StepFailedError < RuntimeError; end

    # Where systemd as PID 1 announces itself (sd_booted's check).
    SYSTEMD_RUN_DIR = "/run/systemd/system"

    # What `dev runner status` reports: whether systemd is configured and
    # running, and the keepalive as Task Scheduler reports it — nil when
    # this session has no interop to ask with.
    class Status < T::Struct
      const :systemd_configured, T::Boolean
      const :systemd_active, T::Boolean
      const :interop, T::Boolean
      const :keepalive, T.nilable(WslKeepaliveTask::Observed)
    end

    class << self
      extend T::Sig

      # The WSL runner host for this machine, or nil when the step does not
      # apply (not a WSL2 distro). Never raises for a session that does not
      # name its distro — see #task.
      #
      # @param host [WslHost] the machine
      # @return [WslRunnerHost, nil]
      sig { params(host: WslHost).returns(T.nilable(WslRunnerHost)) }
      def for_host(host: WslHost.new)
        return nil unless host.wsl?

        new(host: host)
      end
    end

    # The task this host's keepalive is, for this session's distro. Built
    # on first use, not at construction: the CLI builds every builtin at
    # startup, and a job under the runner's systemd service has no
    # WSL_DISTRO_NAME in its env — asking there would stop every `dev`
    # command on the box before it parsed argv (dev#564). The name is
    # demanded where the keepalive is converged or inspected.
    #
    # @return [WslKeepaliveTask]
    # @raise [WslHost::DistroUnknownError] when the session does not name its distro
    sig { returns(WslKeepaliveTask) }
    def task
      @task ||= WslKeepaliveTask.new(distro: @host.distro)
    end

    # @param host [WslHost] the WSL machine (interop, the distro's name)
    # @param task [WslKeepaliveTask, nil] the keepalive for this distro; built from the session's distro name on first use
    # @param executor [#run, #capture] process seam for powershell.exe
    # @param steps [Dev::PrivilegedSteps] the sudo contract, for wsl.conf
    # @param wsl [Dev::WslProvisioner] the `.wslconfig` ratchet
    # @param wsl_conf_path [String] the distro's /etc/wsl.conf
    # @param systemd_run_dir [String] where a running systemd announces itself
    # @param out [IO, StringIO] progress stream
    sig do
      params(
        host: WslHost,
        task: T.nilable(WslKeepaliveTask),
        executor: T.untyped,
        steps: PrivilegedSteps,
        wsl: WslProvisioner,
        wsl_conf_path: String,
        systemd_run_dir: String,
        out: T.any(IO, StringIO),
      ).void
    end
    def initialize(host:, task: nil, executor: ProcessExecutor.new,
                   steps: PrivilegedSteps.new(executor: executor, purpose: "enable systemd in #{WslConf::PATH}"),
                   wsl: WslProvisioner.new(host: host, executor: executor), wsl_conf_path: WslConf::PATH,
                   systemd_run_dir: SYSTEMD_RUN_DIR, out: $stdout)
      @host = host
      @task = task
      @executor = executor
      @steps = steps
      @wsl = wsl
      @wsl_conf_path = wsl_conf_path
      @systemd_run_dir = systemd_run_dir
      @out = out
    end

    # Converge the host: the keepalive first (it needs no restart, and a
    # restart the later steps ask for should bring the distro back under
    # it), then systemd in wsl.conf, then `.wslconfig` for the checkout's
    # hint. Re-running changes nothing on a converged host.
    #
    # @param resources [EngineResources::Hint, nil] the checkout's engine hint, if any
    # @return [void]
    # @raise [InteropRequiredError] when this session cannot reach Windows
    # @raise [StepFailedError] when registering or starting the task fails
    # @raise [RestartRequiredError] when systemd was enabled but is not running yet, or `.wslconfig` is ahead of the VM
    # @raise [PrivilegedSteps::StepFailedError, PrivilegedSteps::SudoRequiredError] from the wsl.conf write
    # @raise [WslProvisioner::UnsatisfiableHintError, WslProvisioner::EngineBusyError]
    # @raise [WslHost::InteropError] when a Windows-side probe answers nothing
    # @raise [WslKeepaliveTask::MalformedTaskError] when Task Scheduler's answer is not a task record
    sig { params(resources: T.nilable(EngineResources::Hint)).void }
    def converge!(resources: nil)
      unless @host.interop?
        raise InteropRequiredError,
          "the logon keepalive for #{@host.distro} cannot be converged from this session: Windows is not reachable " \
          "(no WSL interop — a service, an ssh login, or interop disabled), and a runner enrolled without it goes " \
          "down with the distro at the next reboot. Run `dev runner register` from a shell opened in the distro " \
          "on the Windows desktop (Windows Terminal)."
      end

      ensure_keepalive!
      systemd_written = ensure_systemd_configured!
      ratchet_wslconfig!(resources)
      ensure_systemd_running!(written: systemd_written)
    end

    # Read every fact, mutating nothing. Without interop the keepalive is
    # unknown rather than absent.
    #
    # @return [Status]
    # @raise [WslHost::InteropError, WslKeepaliveTask::MalformedTaskError]
    sig { returns(Status) }
    def status
      interop = @host.interop?
      Status.new(
        systemd_configured: WslConf.read(path: @wsl_conf_path).systemd_enabled?,
        systemd_active: systemd_active?,
        interop: interop,
        keepalive: interop ? observe_keepalive : nil,
      )
    end

    private

    # Step 1: the keepalive registered and running. A converged task that is
    # not running is started, not replaced; anything else is (re)registered
    # — unelevated first, then through one UAC prompt when a prior task
    # exists that refused the unelevated write.
    #
    # @raise [StepFailedError]
    sig { void }
    def ensure_keepalive!
      observed = observe_keepalive
      if task.converged?(observed)
        return if observed.running

        @out.puts ">>> Starting the logon keepalive task '#{task.name}' (holds a session so #{task.distro} stays up) ..."
        step!(task.start_script, "start the keepalive task '#{task.name}'")
        return
      end

      @out.puts ">>> Registering the logon keepalive task '#{task.name}' (at log on: #{task.command}) ..."
      task.shortfalls(observed).each { |reason| @out.puts "    #{reason}" } if observed.present
      return if run_powershell(task.register_script)
      raise StepFailedError, "could not register the keepalive task '#{task.name}' (powershell.exe exited nonzero)" unless observed.present

      @out.puts ">>> '#{task.name}' was registered by an administrator, so replacing it needs the same — " \
                "one UAC prompt on the Windows desktop ..."
      step!(task.elevated(task.register_script), "replace the keepalive task '#{task.name}' (elevated)")
    end

    # Step 2: `[boot] systemd=true` in wsl.conf, written through one sudo
    # session when absent.
    #
    # @return [Boolean] whether the file was written (a restart is then due)
    # @raise [PrivilegedSteps::StepFailedError, PrivilegedSteps::SudoRequiredError]
    sig { returns(T::Boolean) }
    def ensure_systemd_configured!
      conf = WslConf.read(path: @wsl_conf_path)
      return false if conf.systemd_enabled?

      @out.puts ">>> Enabling systemd in #{@wsl_conf_path} (one sudo prompt) — the runner service is a systemd unit ..."
      @steps.session!
      @steps.install_file!(conf.with_systemd_enabled.render, @wsl_conf_path, mode: "0644")
      true
    end

    # Step 3: `.wslconfig` for the checkout's hint — the engine step's
    # ratchet, run here for every WSL registration. A pending resize is a
    # restart, and on a runner host a restart has one more step: the
    # keepalive's session died with the VM, and only it holds the distro up.
    #
    # @param resources [EngineResources::Hint, nil]
    # @raise [RestartRequiredError] when `.wslconfig` is ahead of the running VM
    sig { params(resources: T.nilable(EngineResources::Hint)).void }
    def ratchet_wslconfig!(resources)
      @wsl.provision!(cpus: resources&.cpus, memory_gib: resources&.memory_gib)
    rescue WslProvisioner::RestartRequiredError => e
      raise RestartRequiredError, "#{e.message} #{keepalive_after_restart}"
    end

    # Step 4: systemd actually running — a configured-but-not-running
    # systemd is a restart the operator performs.
    #
    # @param written [Boolean] whether this run wrote wsl.conf
    # @raise [RestartRequiredError]
    sig { params(written: T::Boolean).void }
    def ensure_systemd_running!(written:)
      return if systemd_active?

      lead = written ? "systemd was enabled in #{@wsl_conf_path}" : "#{@wsl_conf_path} enables systemd but it is not running"
      raise RestartRequiredError,
        "#{lead}; the runner service is a systemd unit and cannot be installed until the distro restarts. " \
        "From Windows run `wsl --shutdown` (this stops every WSL distro and the runner services in them), " \
        "then `dev runner register` again. #{keepalive_after_restart}"
    end

    # What a restart means on a runner host: the shutdown ends the
    # keepalive's held session too, and a shell opened by hand holds the
    # distro only while it is open.
    #
    # @return [String]
    sig { returns(String) }
    def keepalive_after_restart
      "After the shutdown, `Start-ScheduledTask -TaskName '#{task.name}'` in PowerShell (or log off and on) " \
        "brings #{task.distro} back up under the keepalive's held session — a shell you open instead holds it " \
        "only while it is open."
    end

    # @return [Boolean] whether systemd is PID 1 in this distro
    sig { returns(T::Boolean) }
    def systemd_active?
      File.directory?(@systemd_run_dir)
    end

    # The keepalive as Task Scheduler reports it.
    #
    # @return [WslKeepaliveTask::Observed]
    # @raise [WslHost::InteropError] when powershell.exe answers nothing
    # @raise [WslKeepaliveTask::MalformedTaskError]
    sig { returns(WslKeepaliveTask::Observed) }
    def observe_keepalive
      answer = T.unsafe(@executor).capture(*WslHost.powershell_argv(task.probe_script))
      if answer.strip.empty?
        raise WslHost::InteropError,
          "powershell.exe printed nothing for the scheduled task '#{task.name}' — is WSL interop enabled?"
      end

      WslKeepaliveTask.parse_observed(answer)
    end

    # Run a PowerShell script through interop, streaming (an error's text
    # is the operator's context).
    #
    # @param script [String]
    # @return [Boolean]
    sig { params(script: String).returns(T::Boolean) }
    def run_powershell(script)
      T.unsafe(@executor).run(*WslHost.powershell_argv(script))
    end

    # Run a PowerShell script, raising when it fails.
    #
    # @param script [String]
    # @param purpose [String] what failed, for the message
    # @raise [StepFailedError]
    sig { params(script: String, purpose: String).void }
    def step!(script, purpose)
      return if run_powershell(script)

      raise StepFailedError, "could not #{purpose}: powershell.exe exited nonzero"
    end
  end
end

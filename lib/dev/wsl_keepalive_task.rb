# typed: strict
# frozen_string_literal: true

require "json"

require "dev/wsl_host"

module Dev
  # The Windows Task Scheduler task that boots a WSL2 distro at logon and
  # keeps it up — as a value: what the task must be, the
  # PowerShell that registers, starts and reads it, and the verdicts over
  # what Task Scheduler reports.
  #
  # Why a task at all: a WSL2 distro is dormant until a client session asks
  # for it, and WSL stops it ~20 s after its last client session ends. The
  # systemd units inside (the runner services, dockerd) are not sessions,
  # so after a reboot nothing starts the distro, and a task that merely
  # runs `wsl ... /bin/true` brings the services up and then lets WSL kill
  # them. The
  # action therefore *holds* a session: `conhost.exe --headless wsl.exe -d
  # <distro> -u root -- sleep infinity` (conhost keeps the window off the
  # desktop; the task runs in the interactive session). The settings are
  # load-bearing too: no execution time limit (the default kills the held
  # session — and the distro — after three days), and IgnoreNew so a second
  # logon does not stack sessions. The trigger is *at log on*; autologon
  # and at-startup triggers are the box owner's policy, not dev's.
  #
  # The task's name is the one the per-repo bootstrap scripts used, so an
  # existing task is replaced in place rather than duplicated.
  class WslKeepaliveTask
    extend T::Sig

    # Task Scheduler's answer could not be read as the record dev asked for.
    class MalformedTaskError < RuntimeError; end

    EXECUTE = "conhost.exe"

    # The CIM class Task Scheduler reports an *At log on* trigger as.
    LOGON_TRIGGER_CLASS = "MSFT_TaskLogonTrigger"

    # ISO 8601 for "no execution time limit".
    NO_TIME_LIMIT = "PT0S"

    # The multiple-instances policy that does not stack sessions.
    IGNORE_NEW = "IgnoreNew"

    # What Task Scheduler reports about the task: its presence, its state,
    # its action, and the settings the keepalive depends on. ABSENT when
    # there is no task of that name.
    class Observed < T::Struct
      const :present, T::Boolean
      const :running, T::Boolean
      const :execute, String
      const :arguments, String
      const :at_logon, T::Boolean
      const :execution_time_limit, String
      const :multiple_instances, String

      ABSENT = T.let(
        new(present: false, running: false, execute: "", arguments: "", at_logon: false,
          execution_time_limit: "", multiple_instances: ""),
        Observed,
      )
    end

    class << self
      extend T::Sig

      # What the probe script printed, as a record.
      #
      # @param json [String] the probe's stdout
      # @return [Observed]
      # @raise [MalformedTaskError] when it is not the record the probe prints
      sig { params(json: String).returns(Observed) }
      def parse_observed(json)
        data = JSON.parse(json)
        raise MalformedTaskError, "Task Scheduler answered #{json.strip.inspect}, not a task record" unless data.is_a?(Hash)
        return Observed::ABSENT unless data.fetch("present")

        Observed.new(
          present: true,
          running: data.fetch("state") == "Running",
          execute: data.fetch("execute").to_s,
          arguments: data.fetch("arguments").to_s,
          at_logon: Array(data.fetch("triggers")).include?(LOGON_TRIGGER_CLASS),
          execution_time_limit: data.fetch("executionTimeLimit").to_s,
          multiple_instances: data.fetch("multipleInstances").to_s,
        )
      rescue JSON::ParserError, KeyError => e
        raise MalformedTaskError, "Task Scheduler answered #{json.strip.inspect}, not a task record (#{e.message})"
      end

      # A string as a single-quoted PowerShell literal (the one quote form
      # that interpolates nothing).
      #
      # @param value [String]
      # @return [String]
      sig { params(value: String).returns(String) }
      def quote(value)
        "'#{value.gsub("'", "''")}'"
      end
    end

    sig { returns(String) }
    attr_reader :distro

    # @param distro [String] the WSL distro the task boots, as `wsl -d` names it
    sig { params(distro: String).void }
    def initialize(distro:)
      @distro = distro
    end

    # The task's name in Task Scheduler.
    #
    # @return [String]
    sig { returns(String) }
    def name
      "Start-WSL-#{@distro}-Runner"
    end

    # The action's arguments: the session-holding wsl.exe under a headless conhost.
    #
    # @return [String]
    sig { returns(String) }
    def arguments
      "--headless wsl.exe -d #{@distro} -u root -- sleep infinity"
    end

    # The action as one command line, for messages.
    #
    # @return [String]
    sig { returns(String) }
    def command
      "#{EXECUTE} #{arguments}"
    end

    # Whether the observed task's action is this one — the one that holds a
    # session. Execute compares case-insensitively (Windows paths), the
    # arguments exactly.
    #
    # @param observed [Observed]
    # @return [Boolean]
    sig { params(observed: Observed).returns(T::Boolean) }
    def holds_session?(observed)
      return false unless observed.present

      observed.execute.downcase == EXECUTE && observed.arguments == arguments
    end

    # Whether the observed task is the keepalive as dev registers it — the
    # distro autostarts at logon and stays up. Running is a separate fact:
    # a converged task is started, not re-registered.
    #
    # @param observed [Observed]
    # @return [Boolean]
    sig { params(observed: Observed).returns(T::Boolean) }
    def converged?(observed)
      shortfalls(observed).empty?
    end

    # What the observed task lacks to be the keepalive, in words; empty
    # when nothing.
    #
    # @param observed [Observed]
    # @return [Array<String>]
    sig { params(observed: Observed).returns(T::Array[String]) }
    def shortfalls(observed)
      return ["no task named '#{name}'"] unless observed.present

      reasons = []
      reasons << "action does not hold a session (#{observed.execute} #{observed.arguments})" unless holds_session?(observed)
      reasons << "trigger is not at log on" unless observed.at_logon
      reasons << "execution time limit #{observed.execution_time_limit} (the held session would be killed)" unless observed.execution_time_limit == NO_TIME_LIMIT
      reasons << "multiple instances #{observed.multiple_instances}, not #{IGNORE_NEW}" unless observed.multiple_instances == IGNORE_NEW
      reasons
    end

    # The PowerShell that reads the task: one JSON record on stdout, with
    # `present: false` when there is no such task — so an empty answer is
    # interop failing, never absence.
    #
    # @return [String]
    sig { returns(String) }
    def probe_script
      <<~POWERSHELL
        $task = Get-ScheduledTask -TaskName #{quoted_name} -ErrorAction SilentlyContinue
        if ($null -eq $task) { '{"present":false}'; exit 0 }
        $action = @($task.Actions)[0]
        [pscustomobject]@{
          present = $true
          state = "$($task.State)"
          execute = "$($action.Execute)"
          arguments = "$($action.Arguments)"
          triggers = @($task.Triggers | ForEach-Object { $_.CimClass.CimClassName })
          executionTimeLimit = "$($task.Settings.ExecutionTimeLimit)"
          multipleInstances = "$($task.Settings.MultipleInstances)"
        } | ConvertTo-Json -Compress
      POWERSHELL
    end

    # The PowerShell that registers the task — replacing one of the same
    # name — as the logged-on user (interactive, not elevated), then starts
    # it so the session is held now rather than at the next logon. The
    # battery settings keep a laptop from suspending the task; the
    # ScheduledTasks cmdlets ignore $ErrorActionPreference, hence the
    # explicit -ErrorAction Stop.
    #
    # @return [String]
    sig { returns(String) }
    def register_script
      <<~POWERSHELL
        $ErrorActionPreference = 'Stop'
        $action = New-ScheduledTaskAction -Execute #{self.class.quote(EXECUTE)} -Argument #{self.class.quote(arguments)}
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
          -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances #{IGNORE_NEW}
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\\$env:USERNAME" -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName #{quoted_name} -Action $action -Trigger $trigger -Settings $settings `
          -Principal $principal -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName #{quoted_name} -ErrorAction Stop
      POWERSHELL
    end

    # The PowerShell that starts a registered task.
    #
    # @return [String]
    sig { returns(String) }
    def start_script
      <<~POWERSHELL
        $ErrorActionPreference = 'Stop'
        Start-ScheduledTask -TaskName #{quoted_name} -ErrorAction Stop
      POWERSHELL
    end

    # A script re-run elevated: one UAC prompt on the Windows desktop, the
    # inner PowerShell's exit code as this one's. Needed when a prior task
    # was registered by an administrator (the per-repo bootstraps did), so
    # its task file is Administrators' and replacing it needs the same.
    #
    # @param script [String] PowerShell source
    # @return [String]
    sig { params(script: String).returns(String) }
    def elevated(script)
      inner = WslHost.powershell_argv(script).drop(1).map { |arg| self.class.quote(arg) }.join(", ")
      <<~POWERSHELL
        $ErrorActionPreference = 'Stop'
        $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -ArgumentList @(#{inner})
        exit $process.ExitCode
      POWERSHELL
    end

    private

    # @return [String] the task name as a PowerShell literal
    sig { returns(String) }
    def quoted_name
      self.class.quote(name)
    end
  end
end

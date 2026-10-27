# typed: strict
# frozen_string_literal: true

require "etc"
require "stringio"

require "dev/linux_data_root_provisioner"
require "dev/platform"
require "dev/privileged_steps"
require "dev/runner_setup"

module Dev
  # The OS user a Linux host's runner services run as (dev#310) — the
  # host rule `dev runner register` applies by default, not a flag the
  # operator has to remember.
  #
  # Three identities meet in a registration, with three different
  # privilege needs: the *operator* mints the registration token (that
  # needs repo admin, or `admin:org`) and installs the service unit (root);
  # the *runner user* owns the enrollment — the dir, `config.sh`'s record,
  # and the `gh` login every job on this host fetches private dependencies
  # with — and holds nothing else: no sudo, no password, a home the
  # operator can read (`0755`: enrollments are inspected from it) but the
  # runner cannot read the operator's; and *GitHub's* job token writes what
  # a job must write to its own repo. Keeping the operator's own login out
  # of the runner's reach is the point: a job that runs as the operator
  # runs with the operator's credentials.
  #
  # The runner user is in `docker` (the engine's socket) and the data
  # root's group (LinuxDataRootProvisioner::GROUP: one tree, two
  # writers). Its gh login is the machine user's token, pasted once by the
  # operator on stdin — dev never sees or stores it, and refuses to enroll
  # while the login is missing, naming the command.
  #
  # macOS has no runner user: the service is a per-user LaunchAgent and the
  # agent user is its own identity there (AgentBootstrap). `for_host`
  # answers nil and register runs as it always has.
  class RunnerUser
    extend T::Sig

    # The runner user has no gh login; the message carries the command.
    class GhLoginRequiredError < RuntimeError; end

    # The host rule's name; `--as` overrides it.
    DEFAULT_NAME = "runner"

    # The groups the runner user needs: the engine's socket and the shared
    # data root.
    GROUPS = T.let(["docker", LinuxDataRootProvisioner::GROUP].freeze, T::Array[String])

    # A passwd lookup: the user's home, or nil when there is no such user.
    HomeOf = T.type_alias { T.proc.params(name: String).returns(T.nilable(String)) }

    # The system's PATH on a Debian-family host; the runner user's PATH
    # starts from it, never from the operator's.
    SYSTEM_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    # Homebrew's shellenv for every login shell on the host — the runner
    # user's included — so `sudo -iu runner gh ...` finds what brew
    # installed. One root-owned file, converged with the user.
    PROFILE_D = "/etc/profile.d/linuxbrew.sh"

    sig { returns(String) }
    attr_reader :name

    # The PATH the runner user's commands run on: dev's probes, config.sh
    # (whose capture of it becomes every job's PATH), the gh login check.
    sig { returns(String) }
    attr_reader :path

    class << self
      extend T::Sig

      # The runner user for this host, or nil when the host rule does not
      # apply (not Linux).
      #
      # @param name [String, nil] `--as` override
      # @param host_os [String] "darwin" / "linux" / "windows"
      # @return [RunnerUser, nil]
      sig { params(name: T.nilable(String), host_os: String).returns(T.nilable(RunnerUser)) }
      def for_host(name: nil, host_os: Platform.os)
        return nil unless host_os == "linux"

        new(name: name || DEFAULT_NAME)
      end

      # The home of a user in passwd, or nil when there is no such user.
      #
      # @param user [String]
      # @return [String, nil]
      sig { params(user: String).returns(T.nilable(String)) }
      def passwd_home(user)
        Etc.getpwnam(user)&.dir
      rescue ArgumentError
        nil
      end

      # Homebrew's binary as the operator's PATH resolves it (symlinks
      # followed), or nil without one.
      #
      # @param env_path [String]
      # @return [String, nil]
      sig { params(env_path: String).returns(T.nilable(String)) }
      def brew_path(env_path: ENV.fetch("PATH", ""))
        found = env_path.split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "brew") }.find { |candidate| File.executable?(candidate) }
        found && File.realpath(found)
      end

      # The PATH the runner user's commands run on: brew's bin and sbin
      # ahead of the system's, nothing of the operator's. `config.sh`
      # records the PATH it is run with, and the runner hands that to every
      # job — so this is the jobs' PATH too, deliberate rather than whatever
      # the operator's shell carried.
      #
      # @param brew [String, nil] brew's binary
      # @return [String]
      sig { params(brew: T.nilable(String)).returns(String) }
      def host_path(brew: brew_path)
        return SYSTEM_PATH unless brew

        prefix = File.dirname(File.dirname(brew))
        "#{prefix}/bin:#{prefix}/sbin:#{SYSTEM_PATH}"
      end
    end

    # @param name [String] the OS user name
    # @param steps [Dev::PrivilegedSteps] the sudo contract
    # @param executor [#capture] CLI boundary for the gh probe
    # @param out [IO, StringIO]
    # @param home_of [Proc] passwd lookup (injectable for tests)
    # @param brew [String, nil] Homebrew's binary on this host, if any
    # @param path [String] the PATH the runner user's commands run on
    sig do
      params(
        name: String,
        steps: PrivilegedSteps,
        executor: T.untyped,
        out: T.any(IO, StringIO),
        home_of: HomeOf,
        brew: T.nilable(String),
        path: String,
      ).void
    end
    def initialize(name:, steps: PrivilegedSteps.new(purpose: "create the runner user #{name}"),
                   executor: RunnerSetup::Executor.new, out: $stdout,
                   home_of: ->(user) { RunnerUser.passwd_home(user) },
                   brew: RunnerUser.brew_path, path: RunnerUser.host_path(brew: brew))
      @name = name
      @steps = steps
      @exec = executor
      @out = out
      @home_of = home_of
      @brew = brew
      @path = path
    end

    # @return [Boolean] whether the user exists
    sig { returns(T::Boolean) }
    def exists?
      !@home_of.call(@name).nil?
    end

    # The user's home: its passwd entry, or where useradd will put it.
    #
    # @return [String]
    sig { returns(String) }
    def home
      @home_of.call(@name) || "/home/#{@name}"
    end

    # Make the user exist, in its groups, with brew in every login shell:
    # one sudo session, one argv per step. Idempotent — a present user has
    # its membership converged, the profile.d file is rewritten in place.
    #
    # @return [void]
    # @raise [PrivilegedSteps::StepFailedError, PrivilegedSteps::SudoRequiredError]
    sig { void }
    def converge!
      present = exists?
      @out.puts ">>> Creating the runner user #{@name} (one sudo prompt) ..." unless present
      @steps.session!
      GROUPS.each { |group| @steps.step!("sudo", "groupadd", "-f", group) }
      if present
        @steps.step!("sudo", "usermod", "-aG", GROUPS.join(","), @name)
      else
        @steps.step!("sudo", "useradd", "-m", "-s", "/bin/bash", "-G", GROUPS.join(","), @name)
        @steps.step!("sudo", "chmod", "0755", home)
      end
      brew = @brew
      @steps.install_file!("eval \"$(#{brew} shellenv)\"\n", PROFILE_D, mode: "0644") if brew
    end

    # The runner user's gh must be logged in before anything enrolls: it
    # is the identity every job fetches with.
    #
    # @return [void]
    # @raise [GhLoginRequiredError] with the login command
    sig { void }
    def ensure_gh_authenticated!
      _out, _err, ok = @exec.capture(*sudo_argv("gh", "auth", "status"))
      return if ok

      raise GhLoginRequiredError,
        "#{@name} has no GitHub login, and every job on this host fetches as #{@name}. Log it in once — " \
        "paste the machine user's token (read access to what the jobs fetch; never an admin's), then Ctrl-D:\n  " \
        "#{login_command}\nthen re-run dev runner register."
    end

    # The one command that logs the runner user in; the token rides stdin.
    #
    # @return [String]
    sig { returns(String) }
    def login_command
      "sudo -iu #{@name} gh auth login --with-token"
    end

    # Run a command as the runner user, in its own home, on the host's
    # PATH (#path) — sudo's and the operator's are neither.
    #
    # @param cmd [Array<String>]
    # @return [Array<String>]
    sig { params(cmd: String).returns(T::Array[String]) }
    def sudo_argv(*cmd)
      ["sudo", "-u", @name, "-H", "env", "PATH=#{@path}", *cmd]
    end
  end
end

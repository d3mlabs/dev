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

    # What the machine user's token must carry, and why each: `repo` for
    # the private fetches (the jobs' dependencies live under two owners,
    # which a fine-grained token cannot span — so a classic token),
    # `read:org` because `gh auth login` refuses a token without it, and
    # `read:packages` because the host's gh token is also its registry
    # login (ghcr pulls). Read-only every one; never an admin's token.
    TOKEN_SCOPES = T.let(%w[repo read:org read:packages].freeze, T::Array[String])

    # The groups the runner user needs: the engine's socket and the shared
    # data root.
    GROUPS = T.let(["docker", LinuxDataRootProvisioner::GROUP].freeze, T::Array[String])

    # A passwd lookup: the user's home, or nil when there is no such user.
    HomeOf = T.type_alias { T.proc.params(name: String).returns(T.nilable(String)) }

    # An ownership lookup: the user name owning a path, or nil when the
    # path is not there.
    OwnerOf = T.type_alias { T.proc.params(path: String).returns(T.nilable(String)) }

    # Linuxbrew's prefix is a dot-directory inside a home made for it.
    LINUXBREW_PREFIX_NAME = ".linuxbrew"

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

      # The user name owning a path, or nil when the path is not there.
      #
      # @param path [String]
      # @return [String, nil]
      sig { params(path: String).returns(T.nilable(String)) }
      def owner_of(path)
        Etc.getpwuid(File.stat(path).uid)&.name
      rescue SystemCallError, ArgumentError
        nil
      end

      # Homebrew's binary as the operator's PATH names it, or nil without
      # one. Never its symlink target: Linuxbrew's `<prefix>/bin/brew` is a
      # link into `<prefix>/Homebrew/bin/brew`, and brew takes its prefix
      # from the path it is invoked by — through the target, `shellenv`
      # answers `<prefix>/Homebrew`, whose bin holds brew alone.
      #
      # @param env_path [String]
      # @return [String, nil]
      sig { params(env_path: String).returns(T.nilable(String)) }
      def brew_path(env_path: ENV.fetch("PATH", ""))
        env_path.split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "brew") }.find { |candidate| File.executable?(candidate) }
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

      # The token in one phrase, for every place that asks for or explains it.
      #
      # @return [String]
      sig { returns(String) }
      def token_hint
        "a classic token with #{TOKEN_SCOPES.join(", ")} — read-only, never an admin's"
      end
    end

    # @param name [String] the OS user name
    # @param steps [Dev::PrivilegedSteps] the sudo contract
    # @param executor [#capture] CLI boundary for the gh probe
    # @param out [IO, StringIO]
    # @param home_of [Proc] passwd lookup (injectable for tests)
    # @param brew [String, nil] Homebrew's binary on this host, if any
    # @param path [String] the PATH the runner user's commands run on
    # @param owner_of [Proc] who owns a path (injectable for tests)
    sig do
      params(
        name: String,
        steps: PrivilegedSteps,
        executor: T.untyped,
        out: T.any(IO, StringIO),
        home_of: HomeOf,
        brew: T.nilable(String),
        path: String,
        owner_of: OwnerOf,
      ).void
    end
    def initialize(name:, steps: PrivilegedSteps.new(purpose: "create the runner user #{name}"),
                   executor: RunnerSetup::Executor.new, out: $stdout,
                   home_of: ->(user) { RunnerUser.passwd_home(user) },
                   brew: RunnerUser.brew_path, path: RunnerUser.host_path(brew: brew),
                   owner_of: ->(path_to_own) { RunnerUser.owner_of(path_to_own) })
      @name = name
      @steps = steps
      @exec = executor
      @out = out
      @home_of = home_of
      @brew = brew
      @path = path
      @owner_of = owner_of
    end

    # The trees that make up the host's toolchain: brew's prefix and, on
    # Linuxbrew, the home it sits in (`/home/linuxbrew/.linuxbrew` and
    # `/home/linuxbrew` — the installer creates both for the same user).
    # Empty on a host without brew.
    #
    # @return [Array<String>]
    sig { returns(T::Array[String]) }
    def toolchain_roots
      brew = @brew
      return [] unless brew

      prefix = File.dirname(File.dirname(brew))
      parent = File.dirname(prefix)
      File.basename(prefix) == LINUXBREW_PREFIX_NAME ? [prefix, parent] : [prefix]
    end

    # Who owns the toolchain: the prefix's owner, nil without brew or a prefix.
    #
    # @return [String, nil]
    sig { returns(T.nilable(String)) }
    def toolchain_owner
      prefix = toolchain_roots.first
      prefix && @owner_of.call(prefix)
    end

    # brew is single-owner, and jobs upgrade dev through it (dev#337): on a
    # Linux build host the prefix is the runner user's by rule. True also
    # without brew — nothing to own, nothing drifted.
    #
    # @return [Boolean]
    sig { returns(T::Boolean) }
    def owns_toolchain?
      owner = toolchain_owner
      owner.nil? || owner == @name
    end

    # The one command that hands the toolchain to the runner user.
    #
    # @return [String]
    sig { returns(String) }
    def chown_command
      "sudo chown -R #{@name}:#{@name} #{toolchain_roots.join(" ")}"
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

    # Make the user exist, in its groups, with brew in every login shell,
    # owning the toolchain: one sudo session, one argv per step.
    # Idempotent — a present user has its membership converged, the
    # profile.d file is rewritten in place, a toolchain already the runner
    # user's is left alone. The hand-over is a step like the others, said
    # out loud, not a question: on a Linux build host the rule is that
    # jobs upgrade dev, and brew is single-owner, so the prefix is the
    # runner user's (dev#337). Aborting leaves the host unmigrated, which
    # `dev runner status` reports until a re-run.
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
      own_toolchain!
    end

    # Hand the toolchain to the runner user when someone else owns it.
    #
    # @return [void]
    sig { void }
    def own_toolchain!
      return if owns_toolchain?

      owner = toolchain_owner
      prefix = toolchain_roots.fetch(0)
      @out.puts ">>> Handing the toolchain #{prefix} (owned by #{owner}) to #{@name}: jobs upgrade dev through it; " \
                "brew as #{owner} becomes `sudo -iu #{@name} brew ...`"
      chown = ["sudo", "chown", "-R", "#{@name}:#{@name}"] + toolchain_roots
      @steps.step!(*T.unsafe(chown))
    end

    # An asker: a question, answered with the secret — or nil/"" when
    # there is no terminal, or the user declined (Dev::Cli::Ui#ask_secret).
    Ask = T.type_alias { T.proc.params(question: String).returns(T.nilable(String)) }

    # The runner user's gh must be logged in before anything enrolls: it
    # is the identity every job fetches with. Missing, and given something
    # to ask with, the token is asked for — hidden input — and handed to
    # `gh auth login --with-token` on stdin as the runner user, in this
    # same run; the status is re-read after. Headless (nothing to ask
    # with, or no answer), the message carries the one command.
    #
    # @param ask [Proc, nil] how to ask for the token at a terminal
    # @return [void]
    # @raise [GhLoginRequiredError] with the login command
    sig { params(ask: T.nilable(Ask)).void }
    def ensure_gh_authenticated!(ask: nil)
      return if gh_authenticated?

      token = ask&.call(
        "#{@name} has no GitHub login, and every job on this host fetches as #{@name}. " \
        "Paste the machine user's token (#{self.class.token_hint})",
      ).to_s.strip
      raise GhLoginRequiredError, headless_message if token.empty?

      _out, err, ok = @exec.capture(*sudo_argv("gh", "auth", "login", "--with-token"), stdin: token)
      return if ok && gh_authenticated?

      raise GhLoginRequiredError,
        "gh did not accept the token for #{@name}: #{err.strip}\n" \
        "It needs #{self.class.token_hint}. Re-run dev runner register with one, or log #{@name} in by hand — " \
        "the token on stdin, then Ctrl-D:\n  #{login_command}"
    end

    # @return [Boolean] whether the runner user's gh is logged in
    sig { returns(T::Boolean) }
    def gh_authenticated?
      _out, _err, ok = @exec.capture(*sudo_argv("gh", "auth", "status"))
      ok
    end

    # The one command that logs the runner user in; the token rides stdin.
    #
    # @return [String]
    sig { returns(String) }
    def login_command
      "sudo -iu #{@name} gh auth login --with-token"
    end

    # What register says when it cannot ask: the command, and what to
    # paste into it.
    #
    # @return [String]
    sig { returns(String) }
    def headless_message
      "#{@name} has no GitHub login, and every job on this host fetches as #{@name}. Log it in once — " \
        "paste the machine user's token (#{self.class.token_hint}), then Ctrl-D:\n  " \
        "#{login_command}\nthen re-run dev runner register."
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

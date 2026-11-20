# typed: strict
# frozen_string_literal: true

require "etc"
require "fileutils"
require "open3"
require "tempfile"

require "dev/data_root"
require "dev/platform"
require "dev/runner_user"
require "dev/tap_trust"
require "dev/ui"

module Dev
  # A **job identity**: the OS user a role's jobs run as, when it is not
  # the runner user — the second identity kind beside RunnerUser (dev#310).
  # A dev.yml role declares one name (`job_identity: <user>`) and `dev
  # runner register` converges everything that name implies, here.
  # Host-singular, idempotent, admin-prompting: every step probes before it
  # mutates, so re-running register re-converges — which is also the drift
  # repair. The result is inspected, never recorded: there is no record
  # file, every fact here is re-derivable from the host, and `dev runner
  # status` reads the same facts through the same object (#group_member?,
  # #cooperative_dir?, #brew_edge, #engine_converged?).
  #
  # What it converges, on every platform: the non-admin user; the
  # cooperative group both identities join — the data root's
  # (DataRoot::GROUP), one name across hosts; the one-way sudoers edge
  # (runner user → job identity, SETENV, with the identity-side umask
  # defaults that keep the dirs it creates group-writable) — and no edge
  # back: the identity writes no brew prefix (#brew_edge); the data root
  # it reads through the group; brew's lock dir as a group space, so its
  # brew reads can take the API download lock in a prefix it does not
  # own; its trust of the deployment's tap (TapTrust — it is a different
  # brew user); and after enrollment, the `_work` tree as a group space
  # and the service env naming the user, the group and the slot.
  #
  # One contract, two adapters: the facts are the same on a Mac and on a
  # Linux dev host; the CLIs that establish them are not, and the *runner
  # user* differs — the operator on a Mac (the service is a per-user
  # LaunchAgent), `runner` on Linux. The platform primitives are the
  # abstract methods below; JobIdentity::Darwin and JobIdentity::Linux
  # implement them, chosen at the composition root (JobIdentity.for_host).
  # What a job identity's tools are is its role's project's business
  # (its dependencies.rb); dev looks none of them up.
  class JobIdentity
    extend T::Sig
    extend T::Helpers
    abstract!

    # A job identity was asked for on a host no adapter converges.
    class UnsupportedPlatformError < RuntimeError; end

    # An admin command exited nonzero — the host is not converged.
    class StepFailedError < RuntimeError; end

    # The service env keys register writes per slot — the single record of
    # "jobs landing here execute as X, in group Y, on slot N" that the
    # dispatcher spawning the identity reads (ai-flow's AgentIsolation).
    # The keys are the contract with that reader and keep their spelling.
    AGENT_USER_ENV = "AI_FLOW_AGENT_USER"
    AGENT_GROUP_ENV = "AI_FLOW_AGENT_GROUP"
    RUNNER_SLOT_ENV = "AI_FLOW_RUNNER_SLOT"

    # The sudoers drop-in carrying the one-way spawn edge. The file keeps
    # the name the agent host bootstrap gave it, so a host converged before
    # the rename is rewritten in place rather than left with two drop-ins.
    SUDOERS_PATH = "/etc/sudoers.d/ai-flow-agent"

    # brew's lock dir under its prefix: HOMEBREW_LOCKS as brew.sh pins it,
    # not overridable, so the identity's locks go where the owner's do.
    BREW_LOCKS = "var/homebrew/locks"

    # The tags the spawn edge carries: no prompt (jobs run unattended) and
    # SETENV (the caller's `VAR=value` assignments ride through). Matched
    # by name, since `sudo -l` prints them in its own order.
    EDGE_TAGS = T.let(%w[NOPASSWD SETENV].freeze, T::Array[String])

    # Why the drop-in carries no brew edge — the fact `dev runner status`
    # reports and the reason register gives for retiring one it finds.
    class NoBrewEdge < T::Struct
      const :reason, String
    end

    # The one reason, on every platform: nothing a job identity does
    # writes a brew prefix. Pins are converged dispatcher-side, by the
    # job's own user, before the identity spawns; gems land in a home the
    # identity owns. A brew *write* as the prefix owner is arbitrary code
    # as that user — on a Linux box a docker-group user, root-equivalent —
    # so the edge was a path across the one line the identity exists to
    # draw (plans#26 scenario G: the agent runs zero setup commands;
    # anything missing is a `WANTED:`).
    NO_BREW_EDGE = T.let(
      NoBrewEdge.new(reason: "the agent writes no prefix: pins are the dispatcher's, gems are the agent's own home — plans#26 G"),
      NoBrewEdge,
    )

    # Runs the admin CLIs. `run` streams (sudo password prompts must reach
    # the terminal), `quiet?` probes success silently, `capture` returns
    # stdout ("" on failure) — the recorded-executor seam tests fake.
    class Executor
      extend T::Sig

      # @param cmd [Array<String>] argv, never a shell string
      # @param chdir [String, nil] working directory for the child
      # @return [Boolean]
      sig { params(cmd: String, chdir: T.nilable(String)).returns(T::Boolean) }
      def run(*cmd, chdir: nil)
        opts = chdir ? { chdir: chdir } : {}
        !!T.unsafe(Kernel).system(*cmd, **opts)
      end

      # @param cmd [Array<String>] argv, never a shell string
      # @return [Boolean]
      sig { params(cmd: String).returns(T::Boolean) }
      def quiet?(*cmd)
        _out, _err, status = T.unsafe(Open3).capture3(*cmd)
        status.success?
      rescue SystemCallError
        false
      end

      # @param cmd [Array<String>] argv, never a shell string
      # @return [String] stdout on success, "" otherwise
      sig { params(cmd: String).returns(String) }
      def capture(*cmd)
        out, _err, status = T.unsafe(Open3).capture3(*cmd)
        status.success? ? out : ""
      rescue SystemCallError
        ""
      end
    end

    # Adapts the executor into the seam ColimaProvisioner and TapTrust run
    # through, crossing the user boundary: every colima invocation runs as
    # the job identity (its VM, its socket), and so does the `brew trust`
    # that lands in its own trust file. Probes use `sudo -n` so a missing
    # credential fails fast instead of hanging on a swallowed password
    # prompt — the caller primes sudo first. `prelude` is what the adapter
    # puts between sudo and the command (Linux: `env -C /`, so the identity
    # is not left in the operator's cwd).
    class SudoUserExecutor
      extend T::Sig

      # @param executor [#run, #quiet?, #capture] the admin CLI seam
      # @param user [String] the job identity's user
      # @param prelude [Array<String>] argv run as the user ahead of every command
      sig { params(executor: T.untyped, user: String, prelude: T::Array[String]).void }
      def initialize(executor:, user:, prelude: [])
        @executor = executor
        @user = user
        @prelude = prelude
      end

      # @param cmd [Array<String>] argv, never a shell string
      # @return [Boolean]
      sig { params(cmd: String).returns(T::Boolean) }
      def run(*cmd)
        T.unsafe(@executor).run("sudo", "-H", "-u", @user, "--", *@prelude, *cmd)
      end

      # @param cmd [Array<String>] argv, never a shell string
      # @return [Boolean]
      sig { params(cmd: String).returns(T::Boolean) }
      def quiet?(*cmd)
        T.unsafe(@executor).quiet?("sudo", "-n", "-H", "-u", @user, "--", *@prelude, *cmd)
      end

      # @param cmd [Array<String>] argv, never a shell string
      # @return [String] stdout on success, "" otherwise
      sig { params(cmd: String).returns(String) }
      def capture(*cmd)
        T.unsafe(@executor).capture("sudo", "-n", "-H", "-u", @user, "--", *@prelude, *cmd)
      end
    end

    class << self
      extend T::Sig

      # The job identity for this host — the composition root: the Darwin
      # adapter on a Mac (the operator is the runner user), the Linux
      # adapter on a Linux dev host (the runner user is). `dev runner
      # status` builds its inspector over the same object, so register and
      # status read one set of facts. The adapters are the caller's to
      # require (`dev/job_identity/darwin`, `dev/job_identity/linux`): each
      # requires this file, so this file cannot require them.
      #
      # @param user [String] the OS user the role's jobs run as
      # @param runner_user [String, nil] the enrolling user; nil for the
      #   platform's default
      # @param executor [#run, #quiet?, #capture] the admin CLI seam
      # @param ui [Ui] where the convergence speaks; the plain tier for a
      #   read-only build (`dev runner status`)
      # @param host_os [String] "darwin" / "linux" / "windows" (injectable for tests)
      # @return [Dev::JobIdentity]
      # @raise [UnsupportedPlatformError] on a host no adapter converges
      sig do
        params(
          user: String,
          runner_user: T.nilable(String),
          executor: T.untyped,
          ui: Ui,
          host_os: String,
        ).returns(JobIdentity)
      end
      def for_host(user:, runner_user: nil, executor: Executor.new, ui: NoUi.new, host_os: Platform.os)
        case host_os
        when "darwin"
          Darwin.new(user: user, executor: executor, ui: ui,
            runner_user: runner_user || T.must(Etc.getpwuid(Process.uid)).name)
        when "linux"
          Linux.new(user: user, executor: executor, ui: ui,
            runner_user: runner_user || RunnerUser::DEFAULT_NAME)
        else
          raise UnsupportedPlatformError,
            "a job identity is converged on a Mac or a Linux dev host; " \
            "a role with job_identity cannot be served by a #{host_os} host."
        end
      end
    end

    # The OS user the role's jobs run as.
    sig { returns(String) }
    attr_reader :user

    # The enrolling user — the sudoers grantor, whose service spawns the
    # job identity: the operator on a Mac, the runner user on Linux.
    sig { returns(String) }
    attr_reader :runner_user

    # The data root both identities resolve on this host.
    sig { returns(String) }
    attr_reader :data_root

    # @param user [String] the OS user to provision
    # @param runner_user [String] the enrolling user (the sudoers grantor)
    # @param executor [#run, #quiet?, #capture] admin CLI seam
    # @param ui [Ui] where the convergence is told: a step per admin
    #   sequence (sudo owns the terminal), a note per fact
    # @param data_root [String] the data root the identity joins
    # @param brew_executable [String, nil] the host's brew binary (nil = no
    #   lock dir to share, no tap to trust)
    # @param owner_of [Proc] who owns a path — whether the brew prefix is
    #   another user's decides the lock dir grant (RunnerUser::OwnerOf;
    #   injectable for tests)
    # @param tap [Dev::TapTrust::Tap, nil] the deployment's tap, which the
    #   identity must trust before brew will load its formulae for it
    #   (TapTrust); nil for none
    # @param as_user_prelude [Array<String>] the adapter's argv ahead of
    #   every command run as the identity (SudoUserExecutor)
    sig do
      params(
        user: String,
        runner_user: String,
        executor: T.untyped,
        ui: Ui,
        data_root: String,
        brew_executable: T.nilable(String),
        owner_of: RunnerUser::OwnerOf,
        tap: T.nilable(TapTrust::Tap),
        as_user_prelude: T::Array[String],
      ).void
    end
    def initialize(user:, runner_user:, executor:, ui:, data_root:, brew_executable:, owner_of:, tap:,
                   as_user_prelude: [])
      @user = user
      @runner_user = runner_user
      @executor = executor
      @ui = ui
      @data_root = data_root
      @brew_executable = brew_executable
      @owner_of = owner_of
      @as_user = T.let(
        SudoUserExecutor.new(executor: executor, user: user, prelude: as_user_prelude),
        SudoUserExecutor,
      )
      # `run` streams: the trust step may be the first sudo of a converged
      # host's re-run, and its password prompt has to reach the terminal.
      @tap_trust = T.let(
        TapTrust.new(user: user, brew: brew_executable, tap: tap, ui: ui,
          run_as_user: ->(argv) { @as_user.run(*argv) }),
        TapTrust,
      )
    end

    # Converge the host-singular facts: the user, the group, the sudoers
    # edge, the data root, and the identity's trust of the deployment's
    # tap (after the user exists to hold it).
    #
    # @return [void]
    # @raise [StepFailedError] when an admin command fails
    sig { void }
    def converge!
      ensure_user!
      ensure_group!
      ensure_sudoers!
      ensure_data_root!
      ensure_brew_locks!
      @tap_trust.trust!
    end

    # Invoked by register only when a served repo's lock pins an image
    # (the only place local-vs-remote is expressed): the identity's own
    # container engine, where the platform has one for it.
    #
    # @param cpus [Integer, nil] VM sizing hint (repo resources block)
    # @param memory_gib [Integer, nil] VM sizing hint
    # @param disk_gib [Integer, nil] VM disk hint (grow-only)
    # @return [void]
    # @raise [StepFailedError] when a converge step fails
    sig { abstract.params(cpus: T.nilable(Integer), memory_gib: T.nilable(Integer), disk_gib: T.nilable(Integer)).void }
    def ensure_engine!(cpus: nil, memory_gib: nil, disk_gib: nil); end

    # Run after the enrollment ceremony (they touch artifacts config.sh and
    # svc.sh just created): the `_work` job-checkout tree becomes a
    # cooperative read-write space (the workdir the identity edits in
    # place), and the runner service gets its env (#service_env) under a
    # 002 umask so re-checkouts stay group-accessible.
    #
    # @param runner_dir [String] the enrolled runner's install dir
    # @param slot [Integer] which of the host's slots this runner is, 1-based
    # @return [void]
    # @raise [StepFailedError] when a converge step fails
    sig { params(runner_dir: String, slot: Integer).void }
    def after_enroll!(runner_dir:, slot:)
      grant_work_tree!(runner_dir)
      configure_service!(runner_dir, slot)
    end

    # The service env one slot's runner carries: the user (jobs landing
    # here execute as X — no manual env step), the group the dispatcher
    # shares fresh workspaces with, and which of the host's slots this is
    # (the dispatcher keys per-slot state by it, and only dev knows the
    # naming). One record, written by both adapters in their service's
    # own shape.
    #
    # @param slot [Integer] 1-based
    # @return [Hash{String => String}]
    sig { params(slot: Integer).returns(T::Hash[String, String]) }
    def service_env(slot)
      { AGENT_USER_ENV => @user, AGENT_GROUP_ENV => DataRoot::GROUP, RUNNER_SLOT_ENV => slot.to_s }
    end

    # The sudoers drop-in content: the one-way NOPASSWD SETENV edge (env is
    # allowlisted by the caller's --preserve-env, which is why SETENV is
    # safe here), plus the identity-side umask defaults that keep the dirs
    # it creates group-accessible for the dispatcher's cleanup and `git
    # add`. Nothing grants the identity anything: a drop-in carrying a
    # brew edge from an earlier register differs from this and is
    # rewritten without it (#ensure_sudoers!).
    #
    # @return [String]
    sig { returns(String) }
    def sudoers_content
      lines = [
        "#{@runner_user} ALL=(#{@user}) #{EDGE_TAGS.join(":")}: ALL",
        "Defaults>#{@user} env_reset, umask=0002, umask_override",
      ]
      "#{lines.join("\n")}\n"
    end

    # Inspection: what the drop-in does about brew — nothing, and why
    # (NO_BREW_EDGE). Dev::Deps::BrewIntegration's escalation still exists
    # — a password prompt for a human at a terminal, `sudo -n` for a
    # headless caller whose host grants a rule by other means; for the
    # identity its refusal is the posture, reported as a `WANTED:`.
    #
    # @return [NoBrewEdge]
    sig { returns(NoBrewEdge) }
    def brew_edge
      NO_BREW_EDGE
    end

    # Inspection: the brew prefix the identity reads but does not own —
    # the operator's on a Mac, the runner user's on a Linux box — whose
    # lock dir is therefore its concern. nil without brew (or a prefix no
    # longer there), or when the identity owns the prefix itself.
    #
    # @return [String, nil]
    sig { returns(T.nilable(String)) }
    def shared_brew_prefix
      brew = @brew_executable
      return nil unless brew

      prefix = prefix_of(brew)
      owner = @owner_of.call(prefix)
      owner && owner != @user ? prefix : nil
    end

    # Inspection: brew's lock dir on a host whose brew the identity uses
    # but does not own (#shared_brew_prefix) — `<prefix>/var/homebrew/locks`,
    # where brew.sh pins HOMEBREW_LOCKS (not overridable). nil without
    # brew, or when the identity owns the prefix and takes its own locks.
    #
    # @return [String, nil]
    sig { returns(T.nilable(String)) }
    def brew_locks_dir
      prefix = shared_brew_prefix
      prefix && File.join(prefix, BREW_LOCKS)
    end

    # Inspection: whether the identity can take brew's locks — the dir a
    # cooperative space and every lock in it open to the group (brew opens
    # an existing lock read-write and never deletes one, so a lock the
    # owner left 0644 is as closed as the dir was). true where no lock dir
    # is the identity's concern.
    #
    # @return [Boolean]
    sig { returns(T::Boolean) }
    def brew_locks_cooperative?
      dir = brew_locks_dir
      return true if dir.nil?

      cooperative_dir?(dir) && @executor.capture("find", dir, "!", "-perm", "-g+w").strip.empty?
    end

    # Inspection: whether a user is in the cooperative group — the probe
    # `dev runner status` reads, never a mutation.
    #
    # @param member [String] a user name
    # @return [Boolean]
    sig { abstract.params(member: String).returns(T::Boolean) }
    def group_member?(member); end

    # Inspection: whether a directory is a cooperative space — in the group,
    # setgid so new entries inherit it. Read via stat, so inspection needs
    # no privileges; false for a missing dir (stat says nothing).
    #
    # @param path [String]
    # @return [Boolean]
    sig { params(path: String).returns(T::Boolean) }
    def cooperative_dir?(path)
      group, perms = @executor.capture(*stat_argv(path)).strip.split(" ", 2)
      # perms renders "drwxrwsr-x": type + owner triplet + group triplet —
      # setgid shows as "s" in the group execute slot, index 6.
      group == DataRoot::GROUP && perms.to_s[6] == "s"
    end

    # Inspection: whether an enrollment's `_work` tree is the cooperative
    # space #after_enroll! grants.
    #
    # @param runner_dir [String]
    # @return [Boolean]
    sig { params(runner_dir: String).returns(T::Boolean) }
    def work_tree_cooperative?(runner_dir)
      cooperative_dir?(File.join(runner_dir, "_work"))
    end

    # Inspection: whether the identity's container engine is in place,
    # where the platform has one (asked only for a served repo that pins
    # an image).
    #
    # @return [Boolean]
    sig { abstract.returns(T::Boolean) }
    def engine_converged?; end

    # Inspection: the engine fact in words, for the status line.
    #
    # @return [String]
    sig { abstract.returns(String) }
    def engine_fact; end

    private

    # Step 1: the non-admin user with its own home, when absent.
    sig { void }
    def ensure_user!
      return if @executor.quiet?("id", "-u", @user)

      @ui.step("Creating the #{@user} user (non-admin)") { create_user! }
    end

    # Step 2: the cooperative group with both identities enrolled.
    sig { void }
    def ensure_group!
      @ui.step("Creating the #{DataRoot::GROUP} group") { create_group! } unless group_exists?

      [@runner_user, @user].each do |member|
        next if group_member?(member)

        @ui.step("Adding #{member} to the #{DataRoot::GROUP} group") { add_group_member!(member) }
      end
    end

    # Step 3: the sudoers drop-in, staged and visudo-validated before it
    # lands (a bad sudoers file can lock sudo out of the whole box), then
    # installed root-owned 0440 so the identity can never rewrite its own
    # edge. Compared whole, so a drop-in still carrying the brew edge an
    # earlier register wrote is replaced by one without it — the drift
    # repair.
    sig { void }
    def ensure_sudoers!
      desired = sudoers_content
      return if @executor.capture("sudo", "cat", SUDOERS_PATH) == desired

      @ui.step("Installing the sudoers edge (#{SUDOERS_PATH})") do
        Tempfile.create("ai-flow-agent-sudoers") do |staging|
          staging.write(desired)
          staging.flush
          File.chmod(0o644, staging.path)
          step!("sudo", "visudo", "-c", "-f", staging.path)
          step!("sudo", "install", "-m", "0440", "-o", "root", staging.path, SUDOERS_PATH)
        end
      end
    end

    # Step 5b: brew's lock dir as a cooperative space, before the
    # identity's first brew (the tap trust). Every brew read by a user
    # with no API cache downloads the signed index under a lock in
    # `<prefix>/var/homebrew/locks`, which the prefix owner alone could
    # write — so on the box `brew trust` as the agent died on
    # `packages.x86_64_linux.jws.json.download.lock`. The dir holds no code
    # and no trust state (trust is per user, under the identity's home): a
    # lock file is the one thing in the prefix the identity writes, and it
    # changes nothing brew installs or runs. Re-granted whenever a lock in
    # it is closed to the group — the owner's interactive brew leaves 0644
    # locks behind.
    sig { void }
    def ensure_brew_locks!
      dir = brew_locks_dir
      return if dir.nil? || brew_locks_cooperative?

      @ui.step("Granting the #{DataRoot::GROUP} group cooperative access to brew's lock dir #{dir}") do
        step!("sudo", "mkdir", "-p", dir)
        step!("sudo", "chgrp", "-R", DataRoot::GROUP, dir)
        step!("sudo", "chmod", "-R", "g+rwX", dir)
        step!("sudo", "chmod", "g+s", dir)
      end
    end

    # Step 4: the `_work` tree as a cooperative read-write space — the
    # group, group-writable, setgid dirs so re-checkouts inherit the
    # group. Unconditional, so a tree from before the group's name was
    # the data root's is re-grouped on the next register. The tree is made
    # under root as the runner user's own: the runner dir is that user's,
    # which on Linux is not the operator running this, and the
    # first job has not created `_work` yet.
    #
    # @param runner_dir [String]
    sig { params(runner_dir: String).void }
    def grant_work_tree!(runner_dir)
      work = File.join(runner_dir, "_work")
      @ui.step("Granting the #{DataRoot::GROUP} group cooperative access to #{work}") do
        step!("sudo", "install", "-d", "-o", @runner_user, "-g", DataRoot::GROUP, "-m", "2775", work)
        step!("sudo", "chgrp", "-R", DataRoot::GROUP, work)
        step!("sudo", "chmod", "-R", "g+rwX", work)
        step!("sudo", "find", work, "-type", "d", "-exec", "chmod", "g+s", "{}", "+")
      end
    end

    # The brew prefix a binary in its bin belongs to (`<prefix>/bin/<name>`).
    #
    # @param binary [String]
    # @return [String]
    sig { params(binary: String).returns(String) }
    def prefix_of(binary)
      File.dirname(File.dirname(binary))
    end

    # The runner service record svc.sh wrote at install — the one fact the
    # service env step hangs off.
    #
    # @param runner_dir [String]
    # @return [String] the record's content, stripped
    # @raise [StepFailedError] when no service was installed in runner_dir
    sig { params(runner_dir: String).returns(String) }
    def service_record(runner_dir)
      service_file = File.join(runner_dir, ".service")
      unless File.exist?(service_file)
        raise StepFailedError,
          "no runner service record at #{service_file} — did the enrollment ceremony run?"
      end

      File.read(service_file).strip
    end

    # Run an admin command, raising when it fails.
    #
    # @param cmd [Array<String>] argv
    # @param chdir [String, nil] working directory for the child
    # @raise [StepFailedError]
    sig { params(cmd: String, chdir: T.nilable(String)).void }
    def step!(*cmd, chdir: nil)
      return if T.unsafe(@executor).run(*cmd, chdir: chdir)

      raise StepFailedError, "job identity step failed: #{cmd.join(" ")}"
    end

    # The platform primitives.

    # Create the user with its own home — no admin, no password.
    sig { abstract.void }
    def create_user!; end

    # Whether the cooperative group exists on the host.
    #
    # @return [Boolean]
    sig { abstract.returns(T::Boolean) }
    def group_exists?; end

    # Create the cooperative group.
    sig { abstract.void }
    def create_group!; end

    # Add a user to the cooperative group.
    #
    # @param member [String]
    sig { abstract.params(member: String).void }
    def add_group_member!(member); end

    # Step 5: the data root both identities resolve, in the shape the
    # identity reads it through the group.
    sig { abstract.void }
    def ensure_data_root!; end

    # Step 7: the runner service carries #service_env under a 002 umask,
    # applied between a service stop and start so the service manager
    # rereads it.
    #
    # @param runner_dir [String]
    # @param slot [Integer] which of the host's slots this runner is
    sig { abstract.params(runner_dir: String, slot: Integer).void }
    def configure_service!(runner_dir, slot); end

    # The stat argv answering "<group> <symbolic mode>" for a path, in the
    # platform's stat dialect.
    #
    # @param path [String]
    # @return [Array<String>]
    sig { abstract.params(path: String).returns(T::Array[String]) }
    def stat_argv(path); end
  end
end

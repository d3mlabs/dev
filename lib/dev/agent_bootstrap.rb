# typed: strict
# frozen_string_literal: true

require "etc"
require "fileutils"
require "open3"
require "tempfile"

require "dev/data_root"
require "dev/runner_user"
require "dev/settings"
require "dev/tap_trust"
require "dev/ui"

module Dev
  # The agent host contract (plans#26 layer 3), converged by `dev runner
  # register` when an advertised label carries it. Host-singular,
  # idempotent, admin-prompting: every step probes before it mutates, so
  # re-running register re-converges — which is also the drift repair. The
  # result is inspected, never recorded: there is no record file, every
  # fact here is re-derivable from the host, and `dev runner status` reads
  # the same facts through the same object (#group_member?,
  # #cooperative_dir?, #brew_edge, #engine_converged?).
  #
  # What it converges, on every platform: the non-admin agent OS user; the
  # cooperative group both identities join — the data root's
  # (DataRoot::GROUP), one name across hosts; the one-way sudoers edge
  # (runner user → agent, SETENV, with the agent-side umask defaults that
  # keep agent-created dirs group-writable) and the brew edge beside it;
  # the data root the agent reads through the group; brew's lock dir as a
  # group space, so the agent's brew reads can take the API download lock
  # in a prefix it does not own (dev#558); the agent's trust of the
  # deployment's tap (TapTrust, dev#374 — the agent is a different brew
  # user); and after enrollment, the `_work` tree as a group space and
  # the service env naming the agent user, the group and the slot.
  #
  # One contract, two adapters (plans#59): the facts are the same on a Mac
  # and on a Linux dev host; the CLIs that establish them are not, and the
  # *runner user* differs — the operator on a Mac (the service is a
  # per-user LaunchAgent), dev#310's `runner` on Linux. The platform
  # primitives are the abstract methods below; AgentBootstrap::Darwin and
  # AgentBootstrap::Linux implement them, chosen at the composition root
  # (LabelContracts.agent_bootstrap). The only constants shared with
  # ai-flow are the user, group and slot names and the env keys that carry
  # them.
  class AgentBootstrap
    extend T::Sig
    extend T::Helpers
    abstract!

    # The agent host bootstrap was requested on a host no adapter converges.
    class UnsupportedPlatformError < RuntimeError; end

    # An admin command exited nonzero — the host is not converged.
    class StepFailedError < RuntimeError; end

    # The run-as identity jobs execute under; a register-time parameter.
    DEFAULT_AGENT_USER = "ai-agent"

    # The service env keys register writes per slot — the single record of
    # "jobs landing here execute as X, in group Y, on slot N" that ai-flow's
    # dispatcher reads (AgentIsolation). Cross-repo literals, duplicated
    # knowingly like the user and group names.
    AGENT_USER_ENV = "AI_FLOW_AGENT_USER"
    AGENT_GROUP_ENV = "AI_FLOW_AGENT_GROUP"
    RUNNER_SLOT_ENV = "AI_FLOW_RUNNER_SLOT"

    # The agent CLI's binary name: the cursor-cli cask's `binary` target,
    # which brew links into `<prefix>/bin` on every platform, and what
    # ai-flow's dispatcher spawns. A cross-repo literal with the deployment
    # Brewfile's cask line, duplicated knowingly like the env keys.
    AGENT_CLI = "cursor-agent"

    # The sudoers drop-in carrying the one-way spawn edge.
    SUDOERS_PATH = "/etc/sudoers.d/ai-flow-agent"

    # brew's lock dir under its prefix: HOMEBREW_LOCKS as brew.sh pins it,
    # not overridable, so the agent's locks go where the owner's do.
    BREW_LOCKS = "var/homebrew/locks"

    # The tags every edge in the drop-in carries: no prompt (jobs run
    # unattended) and SETENV (the caller's `VAR=value` assignments ride
    # through). Matched by name, since `sudo -l` prints them in its own order.
    EDGE_TAGS = T.let(%w[NOPASSWD SETENV].freeze, T::Array[String])

    # The brew escalation edge as facts — who may run which brew as whom —
    # the single description the drop-in's rule is rendered from and the
    # host is inspected against.
    class BrewEdge < T::Struct
      extend T::Sig

      const :agent, String
      const :owner, String
      const :path, String

      # The sudoers rule granting the edge.
      #
      # @return [String]
      sig { returns(String) }
      def sudoers_rule
        "#{agent} ALL=(#{owner}) #{EDGE_TAGS.join(":")}: #{path}"
      end
    end

    # Why the drop-in carries no brew edge: nothing for the agent to escalate.
    class NoBrewEdge < T::Struct
      const :reason, String
    end

    # What the drop-in does about brew: the edge it grants, or why none.
    BrewEdgeDecision = T.type_alias { T.any(BrewEdge, NoBrewEdge) }

    class << self
      extend T::Sig

      # The host's brew binary: `<prefix>/bin/brew` under the prefix dev
      # resolves, when it is there; nil without brew. The prefix's own
      # `bin/brew`, never its realpath — Linuxbrew's is a link into
      # `<prefix>/Homebrew/bin`, and brew takes its prefix from the path it
      # is invoked by (RunnerUser.brew_path says the same).
      #
      # @param prefix [String, nil] the machine's brew prefix
      #   (Settings.brew_prefix; injectable for tests)
      # @return [String, nil]
      sig { params(prefix: T.nilable(String)).returns(T.nilable(String)) }
      def host_brew(prefix: Settings.brew_prefix)
        return nil unless prefix

        brew = File.join(prefix, "bin", "brew")
        File.executable?(brew) ? brew : nil
      end
    end

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

    # Adapts the bootstrap executor into the seam ColimaProvisioner and
    # TapTrust run through, crossing the user boundary: every colima
    # invocation runs as the agent (its VM, its socket), and so does the
    # `brew trust` that lands in the agent's own trust file. Probes use
    # `sudo -n` so a missing credential fails fast instead of hanging on a
    # swallowed password prompt — the caller primes sudo first. `prelude`
    # is what the adapter puts between sudo and the command (Linux: `env -C
    # /`, so the agent is not left in the operator's cwd, dev#493).
    class SudoAgentExecutor
      extend T::Sig

      # @param executor [#run, #quiet?, #capture] the bootstrap's admin CLI seam
      # @param agent_user [String]
      # @param prelude [Array<String>] argv run as the agent ahead of every command
      sig { params(executor: T.untyped, agent_user: String, prelude: T::Array[String]).void }
      def initialize(executor:, agent_user:, prelude: [])
        @executor = executor
        @agent_user = agent_user
        @prelude = prelude
      end

      # @param cmd [Array<String>] argv, never a shell string
      # @return [Boolean]
      sig { params(cmd: String).returns(T::Boolean) }
      def run(*cmd)
        T.unsafe(@executor).run("sudo", "-H", "-u", @agent_user, "--", *@prelude, *cmd)
      end

      # @param cmd [Array<String>] argv, never a shell string
      # @return [Boolean]
      sig { params(cmd: String).returns(T::Boolean) }
      def quiet?(*cmd)
        T.unsafe(@executor).quiet?("sudo", "-n", "-H", "-u", @agent_user, "--", *@prelude, *cmd)
      end

      # @param cmd [Array<String>] argv, never a shell string
      # @return [String] stdout on success, "" otherwise
      sig { params(cmd: String).returns(String) }
      def capture(*cmd)
        T.unsafe(@executor).capture("sudo", "-n", "-H", "-u", @agent_user, "--", *@prelude, *cmd)
      end
    end

    sig { returns(String) }
    attr_reader :agent_user

    # The enrolling user — the sudoers grantor, whose service spawns the
    # agent: the operator on a Mac, the runner user on Linux.
    sig { returns(String) }
    attr_reader :runner_user

    # The data root both identities resolve on this host.
    sig { returns(String) }
    attr_reader :data_root

    # @param agent_user [String] the run-as user to provision
    # @param runner_user [String] the enrolling user (the sudoers grantor)
    # @param executor [#run, #quiet?, #capture] admin CLI seam
    # @param ui [Ui] where the convergence is told: a step per admin
    #   sequence (sudo owns the terminal), a note per fact
    # @param data_root [String] the data root the agent joins
    # @param brew_executable [String, nil] the host's brew binary (nil = no
    #   brew edge, no tap to trust)
    # @param owner_of [Proc] who owns a path — the brew prefix's owner is
    #   the brew edge's grantee (RunnerUser::OwnerOf; injectable for tests)
    # @param tap [Dev::TapTrust::Tap, nil] the deployment's tap, which the
    #   agent user must trust before brew will load its formulae for it
    #   (TapTrust); nil for none
    # @param as_agent_prelude [Array<String>] the adapter's argv ahead of
    #   every command run as the agent (SudoAgentExecutor)
    sig do
      params(
        agent_user: String,
        runner_user: String,
        executor: T.untyped,
        ui: Ui,
        data_root: String,
        brew_executable: T.nilable(String),
        owner_of: RunnerUser::OwnerOf,
        tap: T.nilable(TapTrust::Tap),
        as_agent_prelude: T::Array[String],
      ).void
    end
    def initialize(agent_user:, runner_user:, executor:, ui:, data_root:, brew_executable:, owner_of:, tap:,
                   as_agent_prelude: [])
      @agent_user = agent_user
      @runner_user = runner_user
      @executor = executor
      @ui = ui
      @data_root = data_root
      @brew_executable = brew_executable
      @owner_of = owner_of
      @as_agent = T.let(
        SudoAgentExecutor.new(executor: executor, agent_user: agent_user, prelude: as_agent_prelude),
        SudoAgentExecutor,
      )
      # `run` streams: the trust step may be the first sudo of a converged
      # host's re-run, and its password prompt has to reach the terminal.
      @tap_trust = T.let(
        TapTrust.new(user: agent_user, brew: brew_executable, tap: tap, ui: ui,
          run_as_user: ->(argv) { @as_agent.run(*argv) }),
        TapTrust,
      )
    end

    # Converge the host-singular facts: agent user, group, sudoers edge,
    # the data root, and the agent's trust of the deployment's tap (after
    # the user exists to hold it).
    #
    # @return [void]
    # @raise [StepFailedError] when an admin command fails
    sig { void }
    def converge!
      ensure_agent_user!
      ensure_group!
      ensure_sudoers!
      ensure_data_root!
      ensure_brew_locks!
      @tap_trust.trust!
    end

    # Invoked by the label contract only when a served repo's lock pins an
    # image (the only place local-vs-remote is expressed): the agent's own
    # container engine, where the platform has one for it.
    #
    # @param cpus [Integer, nil] VM sizing hint (repo resources block)
    # @param memory_gib [Integer, nil] VM sizing hint
    # @param disk_gib [Integer, nil] VM disk hint (grow-only)
    # @return [void]
    # @raise [StepFailedError] when a converge step fails
    sig { abstract.params(cpus: T.nilable(Integer), memory_gib: T.nilable(Integer), disk_gib: T.nilable(Integer)).void }
    def ensure_agent_engine!(cpus: nil, memory_gib: nil, disk_gib: nil); end

    # Run after the enrollment ceremony (they touch artifacts config.sh and
    # svc.sh just created): the `_work` job-checkout tree becomes a
    # cooperative read-write space (the @workdir that /ask, /split, and
    # PR-mode /build edit in place), and the runner service gets its env
    # (#service_env) under a 002 umask so re-checkouts stay
    # group-accessible. The agent CLI check is warn-only, read at the
    # channel's landing spot (#agent_cli_path): the cursor-cli cask arrives
    # via the deployment Brewfile on the prefix owner's `dev up`, which may
    # legitimately not have run yet.
    #
    # @param runner_dir [String] the enrolled runner's install dir
    # @param slot [Integer] which of the host's slots this runner is, 1-based
    # @return [void]
    # @raise [StepFailedError] when a converge step fails
    sig { params(runner_dir: String, slot: Integer).void }
    def after_enroll!(runner_dir:, slot:)
      grant_work_tree!(runner_dir)
      configure_service!(runner_dir, slot)
      verify_agent_cli!
    end

    # The service env one slot's runner carries: the agent user (jobs
    # landing here execute as X — no manual env step), the group ai-flow
    # shares fresh workspaces with, and which of the host's slots this is
    # (dev#485: ai-flow keys per-slot state by it, and only dev knows the
    # naming). One record, written by both adapters in their service's
    # own shape.
    #
    # @param slot [Integer] 1-based
    # @return [Hash{String => String}]
    sig { params(slot: Integer).returns(T::Hash[String, String]) }
    def service_env(slot)
      { AGENT_USER_ENV => @agent_user, AGENT_GROUP_ENV => DataRoot::GROUP, RUNNER_SLOT_ENV => slot.to_s }
    end

    # The sudoers drop-in content: the one-way NOPASSWD SETENV edge (env is
    # allowlisted by the caller's --preserve-env, which is why SETENV is
    # safe here), plus the agent-side umask defaults that keep agent-created
    # dirs group-accessible for the dispatcher's cleanup and `git add`,
    # plus the brew escalation edge (when the host has brew).
    #
    # @return [String]
    sig { returns(String) }
    def sudoers_content
      lines = [
        "#{@runner_user} ALL=(#{@agent_user}) #{EDGE_TAGS.join(":")}: ALL",
        "Defaults>#{@agent_user} env_reset, umask=0002, umask_override",
      ]
      edge = brew_edge
      lines << edge.sudoers_rule if edge.is_a?(BrewEdge)
      "#{lines.join("\n")}\n"
    end

    # The brew escalation edge (the Homebrew single-user gap on cooperative
    # machines): the agent may run exactly brew as the prefix owner,
    # NOPASSWD, so `dev deps install` converges formulae without a human
    # even though the prefix belongs to another user — the operator on a
    # Mac, the runner user on a Linux box (dev#337). The owner is stat'd
    # here at bootstrap time — never hardcoded — and re-running register
    # re-converges the edge. Waived when the host has no brew or the agent
    # owns the prefix itself (nothing to escalate). Consumed by
    # Dev::Deps::BrewIntegration's `sudo -n` escalation, which runs this
    # exact path with the brew environment a write needs (its download
    # cache in the store, the pinned-taps variables) as sudo's own
    # `VAR=value` assignments — sudoers matches the command, so nothing
    # may stand in front of brew — and sudo admits those assignments only
    # under SETENV (dev#361). SETENV widens nothing material: a grant to
    # run brew as the owner already runs arbitrary code as the owner
    # (`brew ruby`, `brew sh`, a formula from a local tap).
    #
    # @return [BrewEdge, NoBrewEdge] the edge, or why none is written
    sig { returns(BrewEdgeDecision) }
    def brew_edge
      brew = @brew_executable
      return NoBrewEdge.new(reason: "no brew on this host") unless brew

      prefix = prefix_of(brew)
      owner = @owner_of.call(prefix)
      return NoBrewEdge.new(reason: "no brew on this host") unless owner
      return NoBrewEdge.new(reason: "#{@agent_user} owns the brew prefix #{prefix}") if owner == @agent_user

      BrewEdge.new(agent: @agent_user, owner: owner, path: brew)
    end

    # Inspection: brew's lock dir on a host whose brew the agent uses but
    # does not own (the #brew_edge hosts) — `<prefix>/var/homebrew/locks`,
    # where brew.sh pins HOMEBREW_LOCKS (not overridable). nil without
    # brew, or when the agent owns the prefix and takes its own locks.
    #
    # @return [String, nil]
    sig { returns(T.nilable(String)) }
    def brew_locks_dir
      edge = brew_edge
      edge.is_a?(BrewEdge) ? File.join(prefix_of(edge.path), BREW_LOCKS) : nil
    end

    # Inspection: whether the agent can take brew's locks — the dir a
    # cooperative space and every lock in it open to the group (brew opens
    # an existing lock read-write and never deletes one, so a lock the
    # owner left 0644 is as closed as the dir was). true where no lock dir
    # is the agent's concern.
    #
    # @return [Boolean]
    sig { returns(T::Boolean) }
    def brew_locks_cooperative?
      dir = brew_locks_dir
      return true if dir.nil?

      cooperative_dir?(dir) && @executor.capture("find", dir, "!", "-perm", "-g+w").strip.empty?
    end

    # Inspection: where the agent CLI lands on this host — the cask's
    # `binary` link beside brew in the prefix's bin — or nil on a host
    # without brew, where the deployment Brewfile has no channel to arrive
    # through. A path, never a PATH lookup: the fact belongs to the channel,
    # so it is read where the channel puts it. The enrolling shell's PATH
    # answers for the operator, which on a Linux box is neither the prefix's
    # owner (the runner user, dev#337) nor the identity that runs the CLI.
    #
    # @return [String, nil]
    sig { returns(T.nilable(String)) }
    def agent_cli_path
      brew = @brew_executable
      brew && File.join(File.dirname(brew), AGENT_CLI)
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

    # Inspection: whether the agent's container engine is in place, where
    # the platform has one (asked only for a served repo that pins an image).
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

    # Step 1: the non-admin agent user with its own home, when absent.
    sig { void }
    def ensure_agent_user!
      return if @executor.quiet?("id", "-u", @agent_user)

      @ui.step("Creating the #{@agent_user} user (non-admin)") { create_agent_user! }
    end

    # Step 2: the cooperative group with both identities enrolled.
    sig { void }
    def ensure_group!
      @ui.step("Creating the #{DataRoot::GROUP} group") { create_group! } unless group_exists?

      [@runner_user, @agent_user].each do |member|
        next if group_member?(member)

        @ui.step("Adding #{member} to the #{DataRoot::GROUP} group") { add_group_member!(member) }
      end
    end

    # Step 3: the sudoers drop-in, staged and visudo-validated before it
    # lands (a bad sudoers file can lock sudo out of the whole box), then
    # installed root-owned 0440 so the agent can never rewrite its own edge.
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

    # Step 5b: brew's lock dir as a cooperative space, before the agent's
    # first brew (the tap trust, dev#558). Every brew read by a user with
    # no API cache downloads the signed index under a lock in
    # `<prefix>/var/homebrew/locks`, which the prefix owner alone could
    # write — so on the box `brew trust` as the agent died on
    # `packages.x86_64_linux.jws.json.download.lock`. The dir holds no code
    # and no trust state (trust is per user, under the agent's home), so
    # the grant widens nothing the brew edge has not. Re-granted whenever a
    # lock in it is closed to the group — the owner's interactive brew
    # leaves 0644 locks behind.
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
    # which on Linux is not the operator running this (dev#310), and the
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

    # Note, as a failed state, when the agent CLI has not landed at
    # #agent_cli_path — the cursor-cli cask arrives via the deployment
    # Brewfile on `dev up`, so absence is an ordering fact, not a
    # bootstrap failure. brew is
    # single-owner, so only the prefix owner's `dev up` converges the
    # Brewfile (HostService skips the layer for anyone else): the remedy
    # names that owner, who on a Linux box is the runner user, not the
    # operator reading this.
    sig { void }
    def verify_agent_cli!
      path = agent_cli_path
      if path.nil?
        @ui.note("{{x}} no brew on this host, so the agent CLI (#{AGENT_CLI}) has no channel to arrive " \
                 "through — install Homebrew, then run `dev up`")
        return
      end
      return if File.executable?(path)

      @ui.note("{{x}} the agent CLI is not at #{path} — the cursor-cli cask lands there through the " \
               "deployment Brewfile on #{tooling_converge_remedy(prefix_of(path))}; jobs cannot run until it does")
    end

    # The `dev up` that converges the Brewfile into a prefix: the owner's,
    # with the sudo form for an operator who is not the owner.
    #
    # @param prefix [String] the brew prefix
    # @return [String]
    sig { params(prefix: String).returns(String) }
    def tooling_converge_remedy(prefix)
      owner = @owner_of.call(prefix)
      return "`dev up` as the owner of #{prefix}" unless owner

      "`dev up` as #{owner}, who owns #{prefix} (from another account: `sudo -iu #{owner} dev up`)"
    end

    # The brew prefix a binary in its bin belongs to (`<prefix>/bin/<name>`:
    # brew itself, or a cask's linked binary).
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

    # The group a path carries, "" when it cannot be read.
    #
    # @param path [String]
    # @return [String]
    sig { params(path: String).returns(String) }
    def group_of(path)
      @executor.capture(*stat_argv(path)).strip.split(" ", 2).first.to_s
    end

    # Run an admin command, raising when it fails.
    #
    # @param cmd [Array<String>] argv
    # @param chdir [String, nil] working directory for the child
    # @raise [StepFailedError]
    sig { params(cmd: String, chdir: T.nilable(String)).void }
    def step!(*cmd, chdir: nil)
      return if T.unsafe(@executor).run(*cmd, chdir: chdir)

      raise StepFailedError, "bootstrap step failed: #{cmd.join(" ")}"
    end

    # The platform primitives.

    # Create the agent user with its own home — no admin, no password.
    sig { abstract.void }
    def create_agent_user!; end

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
    # agent reads it through the group.
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

# typed: strict
# frozen_string_literal: true

require "etc"
require "fileutils"
require "open3"
require "stringio"
require "tempfile"
require "yaml"

require "dev/colima_provisioner"
require "dev/data_root"

module Dev
  # The agent host bootstrap (plans#26 layer 3), converged by
  # `dev runner register` when an advertised label carries the agent
  # contract. Host-singular, idempotent, admin-prompting: every step probes
  # before it mutates, so re-running register re-converges — which is also
  # the drift repair. The result is inspected, never recorded: there is no
  # record file, every fact here is re-derivable from the host.
  #
  # What it converges: the hidden non-admin agent OS user, the shared `ai`
  # group, and the one-way sudoers edge (runner user → agent, SETENV, with
  # the agent-side umask defaults that keep agent-created dirs
  # group-writable). The only constants shared with ai-flow are the user and
  # group names.
  #
  # macOS-only today: the admin CLIs (sysadminctl, dseditgroup, visudo) are
  # Darwin's, and the only agent hosts are Macs (plans#26 approach
  # A). A bare registration (no agent labels) never reaches this class.
  class AgentBootstrap
    extend T::Sig

    # The agent host bootstrap was requested on a host it cannot converge.
    class UnsupportedPlatformError < RuntimeError; end

    # An admin command exited nonzero — the host is not converged.
    class StepFailedError < RuntimeError; end

    # The run-as identity jobs execute under; a register-time parameter.
    DEFAULT_AGENT_USER = "ai-agent"

    # The cooperative group both identities join (workspaces, _work, DDC).
    GROUP = "ai"

    # The sudoers drop-in carrying the one-way spawn edge.
    SUDOERS_PATH = "/etc/sudoers.d/ai-flow-agent"

    # The shared DDC directory under the shared root. UE disables a shared
    # cache store whose path is missing rather than creating it (probed on
    # ue5-mac 5.8), so register provisions the leaf; cellbound-3d's committed
    # DDC config points here (a cross-repo literal, duplicated knowingly like
    # the shared root itself — d3mlabs/cellbound-3d#157).
    DDC_DIR = "ddc"

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

    # Adapts the bootstrap executor into ColimaProvisioner's seam, crossing
    # the user boundary: every colima invocation runs as the agent (its VM,
    # its socket). Probes use `sudo -n` so a missing credential fails fast
    # instead of hanging on a swallowed password prompt — the caller primes
    # sudo first.
    class SudoAgentExecutor
      extend T::Sig

      # @param executor [#run, #quiet?] the bootstrap's admin CLI seam
      # @param agent_user [String]
      sig { params(executor: T.untyped, agent_user: String).void }
      def initialize(executor:, agent_user:)
        @executor = executor
        @agent_user = agent_user
      end

      # @param cmd [Array<String>] argv, never a shell string
      # @return [Boolean]
      sig { params(cmd: String).returns(T::Boolean) }
      def run(*cmd)
        T.unsafe(@executor).run("sudo", "-H", "-u", @agent_user, "--", *cmd)
      end

      # @param cmd [Array<String>] argv, never a shell string
      # @return [Boolean]
      sig { params(cmd: String).returns(T::Boolean) }
      def quiet?(*cmd)
        T.unsafe(@executor).quiet?("sudo", "-n", "-H", "-u", @agent_user, "--", *cmd)
      end
    end

    sig { returns(String) }
    attr_reader :agent_user

    # @param agent_user [String] the run-as user to provision
    # @param runner_user [String] the enrolling user (the sudoers grantor);
    #   defaults to whoever is running register
    # @param executor [#run, #quiet?, #capture] admin CLI seam
    # @param out [IO, StringIO] progress stream
    # @param darwin [Boolean] host platform fact (injectable for tests)
    # @param shared_root [String] where the shared data root is provisioned
    # @param home_dev [String] the per-user data dir migrated out of
    # @param launch_agents_dir [String] where svc.sh installs runner plists
    sig do
      params(
        agent_user: String,
        runner_user: String,
        executor: T.untyped,
        out: T.any(IO, StringIO),
        darwin: T::Boolean,
        shared_root: String,
        home_dev: String,
        launch_agents_dir: String,
      ).void
    end
    def initialize(agent_user: DEFAULT_AGENT_USER, runner_user: T.must(Etc.getpwuid(Process.uid)).name,
                   executor: Executor.new, out: $stdout, darwin: RUBY_PLATFORM.include?("darwin"),
                   shared_root: DataRoot::SHARED_ROOT, home_dev: File.expand_path(DataRoot::HOME_ROOT),
                   launch_agents_dir: File.join(Dir.home, "Library", "LaunchAgents"))
      @agent_user = agent_user
      @runner_user = runner_user
      @executor = executor
      @out = out
      @darwin = darwin
      @shared_root = shared_root
      @home_dev = home_dev
      @launch_agents_dir = launch_agents_dir
    end

    # Converge the host-singular facts: agent user, group, sudoers edge,
    # shared root (with the one-off ~/.dev migration).
    #
    # @return [void]
    # @raise [UnsupportedPlatformError] off macOS
    # @raise [StepFailedError] when an admin command fails
    sig { void }
    def converge!
      assert_darwin!
      ensure_agent_user!
      ensure_group!
      ensure_sudoers!
      ensure_shared_root!
    end

    # Step 6, invoked by the label contract only when a served repo declares
    # `build.container` (the only place local-vs-remote is expressed):
    # converge the agent's own engine — colima installed (Docker Desktop
    # cannot serve a no-GUI user), the agent's `container_engine: colima`
    # record written into its own config (resolution never crosses the sudo
    # boundary), and its VM provisioned, sized from the repo's resources
    # hint. Every colima invocation crosses to the agent via sudo.
    #
    # @param cpus [Integer, nil] VM sizing hint (repo resources block)
    # @param memory_gib [Integer, nil] VM sizing hint
    # @return [void]
    # @raise [UnsupportedPlatformError] off macOS
    # @raise [StepFailedError] when a converge step fails
    # @raise [Dev::ColimaProvisioner::StartFailedError] when the VM won't start
    sig { params(cpus: T.nilable(Integer), memory_gib: T.nilable(Integer)).void }
    def ensure_agent_engine!(cpus: nil, memory_gib: nil)
      assert_darwin!
      # Prime the sudo credential once, visibly, so the -n probes below
      # never hang on a captured password prompt.
      step!("sudo", "-v")
      ensure_colima_installed!
      ensure_agent_engine_record!
      ColimaProvisioner
        .new(executor: SudoAgentExecutor.new(executor: @executor, agent_user: @agent_user))
        .provision!(cpus: cpus, memory_gib: memory_gib)
    end

    # Steps 4 and 7, run after the enrollment ceremony (they touch artifacts
    # config.sh/svc.sh just created): the `_work` job-checkout tree becomes a
    # cooperative read-write space (the @workdir that /ask, /split, and
    # PR-mode /build edit in place), and the runner service gets its
    # env — Umask 002 so re-checkouts stay group-accessible, and
    # AI_FLOW_AGENT_USER as the single record of "jobs landing here execute
    # as X" (no manual env step). The agent CLI resolution check is
    # warn-only: the cursor-cli cask arrives via the ai-flow checkout's
    # `dev up`, which may legitimately not have run yet.
    #
    # @param runner_dir [String] the enrolled runner's install dir
    # @return [void]
    # @raise [UnsupportedPlatformError] off macOS
    # @raise [StepFailedError] when a converge step fails
    sig { params(runner_dir: String).void }
    def after_enroll!(runner_dir:)
      assert_darwin!
      grant_work_tree!(runner_dir)
      configure_service!(runner_dir)
      verify_agent_cli!
    end

    # The agent config content carrying the engine record, merged over
    # whatever the agent's config already holds (never clobbers other keys).
    #
    # @param existing [String] current agent config YAML ("" when absent)
    # @return [String]
    sig { params(existing: String).returns(String) }
    def agent_config_content(existing)
      parsed = YAML.safe_load(existing)
      config = parsed.is_a?(Hash) ? parsed : {}
      YAML.dump(config.merge("container_engine" => "colima"))
    end

    # The sudoers drop-in content: the one-way NOPASSWD SETENV edge (env is
    # allowlisted by the caller's --preserve-env, which is why SETENV is
    # safe here), plus the agent-side umask defaults that keep agent-created
    # dirs group-accessible for the dispatcher's cleanup and `git add`.
    #
    # @return [String]
    sig { returns(String) }
    def sudoers_content
      <<~SUDOERS
        #{@runner_user} ALL=(#{@agent_user}) NOPASSWD:SETENV: ALL
        Defaults>#{@agent_user} env_reset, umask=0002, umask_override
      SUDOERS
    end

    private

    # @raise [UnsupportedPlatformError] off macOS
    sig { void }
    def assert_darwin!
      return if @darwin

      raise UnsupportedPlatformError,
        "the agent host bootstrap is macOS-only today (plans#26 approach A); " \
        "agent-capability labels cannot be served by this host."
    end

    # Step 1: the hidden, non-admin agent user with its own home. Hidden and
    # non-admin by construction: no -admin flag, IsHidden set right after
    # creation, home materialized so the agent's per-user state has a place
    # to land before the first job.
    sig { void }
    def ensure_agent_user!
      return if @executor.quiet?("id", "-u", @agent_user)

      @out.puts ">>> Creating the #{@agent_user} user (hidden, non-admin) ..."
      step!("sudo", "sysadminctl", "-addUser", @agent_user, "-fullName", "AI Agent", "-shell", "/bin/zsh")
      step!("sudo", "dscl", ".", "create", "/Users/#{@agent_user}", "IsHidden", "1")
      step!("sudo", "createhomedir", "-c", "-u", @agent_user)
    end

    # Step 2: the ai group with both identities enrolled.
    sig { void }
    def ensure_group!
      unless @executor.quiet?("dseditgroup", "-o", "read", GROUP)
        @out.puts ">>> Creating the #{GROUP} group ..."
        step!("sudo", "dseditgroup", "-o", "create", GROUP)
      end

      [@runner_user, @agent_user].each do |member|
        next if @executor.quiet?("dseditgroup", "-o", "checkmember", "-m", member, GROUP)

        @out.puts ">>> Adding #{member} to the #{GROUP} group ..."
        step!("sudo", "dseditgroup", "-o", "edit", "-a", member, "-t", "user", GROUP)
      end
    end

    # Step 3: the sudoers drop-in, staged and visudo-validated before it
    # lands (a bad sudoers file can lock sudo out of the whole box), then
    # installed root-owned 0440 so the agent can never rewrite its own edge.
    sig { void }
    def ensure_sudoers!
      desired = sudoers_content
      return if @executor.capture("sudo", "cat", SUDOERS_PATH) == desired

      @out.puts ">>> Installing the sudoers edge (#{SUDOERS_PATH}) ..."
      Tempfile.create("ai-flow-agent-sudoers") do |staging|
        staging.write(desired)
        staging.flush
        File.chmod(0o644, staging.path)
        step!("sudo", "visudo", "-c", "-f", staging.path)
        step!("sudo", "install", "-m", "0440", "-o", "root", staging.path, SUDOERS_PATH)
      end
    end

    # Step 5: the shared data root both identities resolve (see
    # Dev::DataRoot — presence is the record), plus the shared DDC leaf the
    # engine expects to pre-exist (DDC_DIR). Fresh dirs get cooperative
    # modes: human-owned so `dev up` writes it, group ai + setgid +
    # group-writable so cooperative caches (the shared DDC) work, world-
    # readable so the agent reads it like /opt/homebrew. An existing dir is
    # left alone — drift shows up in `dev runner status`, and deleting it
    # re-converges. Then the one-off migration.
    sig { void }
    def ensure_shared_root!
      ensure_cooperative_dir!(@shared_root, "the shared root")
      ensure_cooperative_dir!(File.join(@shared_root, DDC_DIR), "the shared DDC")

      migrate_home_artifacts!
    end

    # mkdir + cooperative modes for a shared directory, first time only.
    #
    # @param path [String] absolute directory to provision
    # @param description [String] what the progress line calls it
    sig { params(path: String, description: String).void }
    def ensure_cooperative_dir!(path, description)
      return if File.directory?(path)

      @out.puts ">>> Provisioning #{description} at #{path} ..."
      FileUtils.mkdir_p(path)
      step!("sudo", "chown", @runner_user, path)
      step!("sudo", "chgrp", GROUP, path)
      step!("sudo", "chmod", "2775", path)
    end

    # The one-off ~/.dev migration: artifact trees (engines, caches, steam
    # depots) move to the shared root — a rename, so multi-GB engine trees
    # cost nothing — while mutable per-user state (`state`) stays per-home
    # (plans#26 pollution rule: sharing is for immutable artifacts and
    # cooperative caches, never mutable state). Entries the shared root
    # already holds are skipped: anything cheap is simply re-materialized by
    # the next `dev up`, and a newer shared tree must never be clobbered by
    # a stale home one.
    sig { void }
    def migrate_home_artifacts!
      return unless File.directory?(@home_dev)

      Dir.children(@home_dev).sort.each do |entry|
        next if entry == "state"

        destination = File.join(@shared_root, entry)
        if File.exist?(destination)
          @out.puts ">>> Skipping ~/.dev/#{entry} (already present in the shared root)."
          next
        end

        @out.puts ">>> Migrating ~/.dev/#{entry} to #{destination} ..."
        FileUtils.mv(File.join(@home_dev, entry), destination)
      end
    end

    # @return [String] the agent's own settings file
    sig { returns(String) }
    def agent_config_path
      "/Users/#{@agent_user}/.config/dev/config.yml"
    end

    # colima arrives via brew like every host tool ("brew converges brew").
    sig { void }
    def ensure_colima_installed!
      return if @executor.quiet?("brew", "list", "--formula", "colima")

      @out.puts ">>> Installing colima ..."
      step!("brew", "install", "colima")
    end

    # Write `container_engine: colima` into the agent's own config, agent-
    # owned, preserving any other keys already there.
    sig { void }
    def ensure_agent_engine_record!
      existing = @executor.capture("sudo", "cat", agent_config_path)
      parsed = YAML.safe_load(existing)
      return if parsed.is_a?(Hash) && parsed["container_engine"] == "colima"

      @out.puts ">>> Recording container_engine: colima for #{@agent_user} ..."
      step!("sudo", "-H", "-u", @agent_user, "--", "mkdir", "-p", File.dirname(agent_config_path))
      Tempfile.create("agent-dev-config") do |staging|
        staging.write(agent_config_content(existing))
        staging.flush
        File.chmod(0o644, staging.path)
        step!("sudo", "install", "-m", "0644", "-o", @agent_user, staging.path, agent_config_path)
      end
    end

    # Step 4: the `_work` tree as a cooperative read-write space — group ai,
    # group-writable, setgid dirs so re-checkouts inherit the group.
    #
    # @param runner_dir [String]
    sig { params(runner_dir: String).void }
    def grant_work_tree!(runner_dir)
      work = File.join(runner_dir, "_work")
      FileUtils.mkdir_p(work)
      @out.puts ">>> Granting the #{GROUP} group cooperative access to #{work} ..."
      step!("sudo", "chgrp", "-R", GROUP, work)
      step!("sudo", "chmod", "-R", "g+rwX", work)
      step!("sudo", "find", work, "-type", "d", "-exec", "chmod", "g+s", "{}", "+")
    end

    # Step 7: the runner service plist carries the service env — Umask 002 and
    # AI_FLOW_AGENT_USER — applied between a service stop/start so launchd
    # rereads it. The plist name comes from the `.service` record svc.sh
    # wrote at install.
    #
    # @param runner_dir [String]
    # @raise [StepFailedError] when no service was installed in runner_dir
    sig { params(runner_dir: String).void }
    def configure_service!(runner_dir)
      service_file = File.join(runner_dir, ".service")
      unless File.exist?(service_file)
        raise StepFailedError,
          "no runner service record at #{service_file} — did the enrollment ceremony run?"
      end

      service = File.read(service_file).strip
      plist = File.join(@launch_agents_dir, "#{service}.plist")
      @out.puts ">>> Writing Umask 002 + AI_FLOW_AGENT_USER=#{@agent_user} into #{plist} ..."
      step!("./svc.sh", "stop", chdir: runner_dir)
      plist_set!(plist, "Umask", "integer", "2")
      # The EnvironmentVariables dict may not exist yet; a failed Add just
      # means it already does.
      @executor.run("/usr/libexec/PlistBuddy", "-c", "Add :EnvironmentVariables dict", plist)
      plist_set!(plist, "EnvironmentVariables:AI_FLOW_AGENT_USER", "string", @agent_user)
      step!("./svc.sh", "start", chdir: runner_dir)
    end

    # Set a plist key, adding it when Set finds none (PlistBuddy's Set fails
    # on missing keys; Add fails on existing ones — together they converge).
    #
    # @param plist [String] plist path
    # @param key [String] colon-path below the root
    # @param type [String] PlistBuddy type for Add
    # @param value [String]
    sig { params(plist: String, key: String, type: String, value: String).void }
    def plist_set!(plist, key, type, value)
      return if @executor.run("/usr/libexec/PlistBuddy", "-c", "Set :#{key} #{value}", plist)

      step!("/usr/libexec/PlistBuddy", "-c", "Add :#{key} #{type} #{value}", plist)
    end

    # Warn when the agent CLI does not resolve — the cursor-cli cask arrives
    # via the ai-flow checkout's `dev up`, so absence is an ordering fact,
    # not a bootstrap failure.
    sig { void }
    def verify_agent_cli!
      return if @executor.quiet?("which", "cursor-agent")

      @out.puts ">>> WARNING: the agent CLI (cursor-agent) does not resolve on this host. " \
                "Run `dev up` in the ai-flow checkout to install it."
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
  end
end

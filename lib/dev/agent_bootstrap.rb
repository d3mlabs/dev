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
  # The agent posture bootstrap (plans#26 layer 3), converged by
  # `dev runner register` when an advertised label carries the agent
  # contract. Host-singular, idempotent, admin-prompting: every step probes
  # before it mutates, so re-running register re-converges — which is also
  # the drift repair. The posture is inspected, never recorded: there is no
  # posture file, every fact here is re-derivable from the host.
  #
  # What it converges: the hidden non-admin agent OS user, the shared `ai`
  # group, and the one-way sudoers edge (runner user → agent, SETENV, with
  # the agent-side umask defaults that keep agent-created dirs
  # group-writable). The only constants shared with ai-flow are the user and
  # group names.
  #
  # macOS-only today: the admin CLIs (sysadminctl, dseditgroup, visudo) are
  # Darwin's, and the only agent-posture hosts are Macs (plans#26 approach
  # A). A bare registration (no agent labels) never reaches this class.
  class AgentBootstrap
    extend T::Sig

    # Agent posture was requested on a host this bootstrap cannot converge.
    class UnsupportedPlatformError < RuntimeError; end

    # An admin command exited nonzero — the posture is not converged.
    class StepFailedError < RuntimeError; end

    # The run-as identity jobs execute under; a register-time parameter.
    DEFAULT_AGENT_USER = "ai-agent"

    # The cooperative group both identities join (workspaces, _work, DDC).
    GROUP = "ai"

    # The sudoers drop-in carrying the one-way spawn edge.
    SUDOERS_PATH = "/etc/sudoers.d/ai-flow-agent"

    # Runs the admin CLIs. `run` streams (sudo password prompts must reach
    # the terminal), `quiet?` probes success silently, `capture` returns
    # stdout ("" on failure) — the recorded-executor seam tests fake.
    class Executor
      extend T::Sig

      # @param cmd [Array<String>] argv, never a shell string
      # @return [Boolean]
      sig { params(cmd: String).returns(T::Boolean) }
      def run(*cmd)
        !!T.unsafe(Kernel).system(*cmd)
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
    sig do
      params(
        agent_user: String,
        runner_user: String,
        executor: T.untyped,
        out: T.any(IO, StringIO),
        darwin: T::Boolean,
        shared_root: String,
        home_dev: String,
      ).void
    end
    def initialize(agent_user: DEFAULT_AGENT_USER, runner_user: T.must(Etc.getpwuid(Process.uid)).name,
                   executor: Executor.new, out: $stdout, darwin: RUBY_PLATFORM.include?("darwin"),
                   shared_root: DataRoot::SHARED_ROOT, home_dev: File.expand_path(DataRoot::HOME_ROOT))
      @agent_user = agent_user
      @runner_user = runner_user
      @executor = executor
      @out = out
      @darwin = darwin
      @shared_root = shared_root
      @home_dev = home_dev
    end

    # Converge the host-singular posture: agent user, group, sudoers edge,
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
        "the agent posture bootstrap is macOS-only today (plans#26 approach A); " \
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
    # Dev::DataRoot — presence is the record). Fresh roots get cooperative
    # modes: human-owned so `dev up` writes it, group ai + setgid +
    # group-writable so cooperative caches (the shared DDC) work, world-
    # readable so the agent reads it like /opt/homebrew. An existing root is
    # left alone — drift shows up in `dev runner status`, and deleting the
    # root re-converges. Then the one-off migration.
    sig { void }
    def ensure_shared_root!
      unless File.directory?(@shared_root)
        @out.puts ">>> Provisioning the shared root at #{@shared_root} ..."
        FileUtils.mkdir_p(@shared_root)
        step!("sudo", "chown", @runner_user, @shared_root)
        step!("sudo", "chgrp", GROUP, @shared_root)
        step!("sudo", "chmod", "2775", @shared_root)
      end

      migrate_home_artifacts!
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

    # Run an admin command, raising when it fails.
    #
    # @param cmd [Array<String>] argv
    # @raise [StepFailedError]
    sig { params(cmd: String).void }
    def step!(*cmd)
      return if T.unsafe(@executor).run(*cmd)

      raise StepFailedError, "bootstrap step failed: #{cmd.join(" ")}"
    end
  end
end

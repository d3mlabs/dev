# typed: strict
# frozen_string_literal: true

require "etc"
require "open3"
require "stringio"
require "tempfile"

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

    sig { returns(String) }
    attr_reader :agent_user

    # @param agent_user [String] the run-as user to provision
    # @param runner_user [String] the enrolling user (the sudoers grantor);
    #   defaults to whoever is running register
    # @param executor [#run, #quiet?, #capture] admin CLI seam
    # @param out [IO, StringIO] progress stream
    # @param darwin [Boolean] host platform fact (injectable for tests)
    sig do
      params(
        agent_user: String,
        runner_user: String,
        executor: T.untyped,
        out: T.any(IO, StringIO),
        darwin: T::Boolean,
      ).void
    end
    def initialize(agent_user: DEFAULT_AGENT_USER, runner_user: T.must(Etc.getpwuid(Process.uid)).name,
                   executor: Executor.new, out: $stdout, darwin: RUBY_PLATFORM.include?("darwin"))
      @agent_user = agent_user
      @runner_user = runner_user
      @executor = executor
      @out = out
      @darwin = darwin
    end

    # Converge the host-singular posture: agent user, group, sudoers edge.
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

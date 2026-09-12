# typed: strict
# frozen_string_literal: true

require "etc"
require "json"
require "stringio"

require "dev/agent_bootstrap"
require "dev/data_root"
require "dev/label_contracts"
require "dev/runner_setup"
require "dev/runner_setup_config"
require "dev/settings"

module Dev
  # `dev runner status` — register's inspect-only counterpart:
  # the checkout's `runner:` block vs this host's registration, plus the
  # inspected reality of each advertised label's contract. Nothing here
  # mutates and nothing is recorded — every fact is re-derived from the
  # host every time (plans#26: inspected, never recorded).
  class RunnerStatus
    extend T::Sig

    # @param config [Dev::RunnerSetupConfig] the checkout's runner block
    # @param runner_dir [String] resolved runner install dir
    # @param out [IO, StringIO] report stream
    # @param executor [#quiet?, #capture] probe seam (never mutates)
    # @param agent_user [String] expected run-as user
    # @param runner_user [String] the enrolling user
    # @param shared_root [String] expected shared-root location
    # @param sudoers_path [String] expected sudoers drop-in location
    # @param brewfile_path [String, nil] the org Brewfile (nil when none ships)
    # @param container_required [Boolean] whether the served repo declares build.container
    sig do
      params(
        config: Dev::RunnerSetupConfig,
        runner_dir: String,
        out: T.any(IO, StringIO),
        executor: T.untyped,
        agent_user: String,
        runner_user: String,
        shared_root: String,
        sudoers_path: String,
        brewfile_path: T.nilable(String),
        container_required: T::Boolean,
      ).void
    end
    def initialize(config:, runner_dir: Dev::RunnerSetup.new(config: config).resolve_dir,
                   out: $stdout, executor: AgentBootstrap::Executor.new,
                   agent_user: AgentBootstrap::DEFAULT_AGENT_USER,
                   runner_user: T.must(Etc.getpwuid(Process.uid)).name,
                   shared_root: DataRoot::SHARED_ROOT,
                   sudoers_path: AgentBootstrap::SUDOERS_PATH,
                   brewfile_path: self.class.default_brewfile_path,
                   container_required: false)
      @config = config
      @runner_dir = runner_dir
      @out = out
      @executor = executor
      @agent_user = agent_user
      @runner_user = runner_user
      @shared_root = shared_root
      @sudoers_path = sudoers_path
      @brewfile_path = brewfile_path
      @container_required = container_required
    end

    class << self
      extend T::Sig

      # The org Brewfile beside the system config, when a deployment ships one.
      #
      # @return [String, nil]
      sig { returns(T.nilable(String)) }
      def default_brewfile_path
        system_config = Dev::Settings.new.system_config_path
        system_config && File.join(File.dirname(system_config), "Brewfile")
      end
    end

    # Print the report: registration, per-label facts, host tooling.
    #
    # @return [void]
    sig { void }
    def report
      report_registration
      report_agent_host if LabelContracts.agent_host?(@config.labels)
      report_host_tooling
    end

    private

    # @param ok [Boolean]
    # @param description [String]
    sig { params(ok: T::Boolean, description: String).void }
    def line(ok, description)
      @out.puts "  #{ok ? "[ok]" : "[!!]"} #{description}"
    end

    # The checkout's expected identity vs the enrolled reality, read from
    # the runner's own .runner record (never GitHub — status works offline).
    sig { void }
    def report_registration
      @out.puts "Runner (labels: #{@config.labels}, dir: #{@runner_dir}):"
      scope = registered_scope
      if scope
        line(true, "registered: #{scope}")
      else
        line(false, "not registered (run `dev runner register`)")
      end
    end

    # @return [String, nil] "owner/repo" or "owner" when enrolled, else nil
    sig { returns(T.nilable(String)) }
    def registered_scope
      raw = File.read(File.join(@runner_dir, ".runner"), encoding: "bom|utf-8")
      url = JSON.parse(raw)["gitHubUrl"].to_s
      scope = url.sub(%r{\Ahttps://github\.com/}, "").chomp("/")
      scope.empty? || scope == url ? nil : scope
    rescue JSON::ParserError, Errno::ENOENT
      nil
    end

    # Every fact the agent contract obliges, re-derived from the host.
    sig { void }
    def report_agent_host
      @out.puts "Agent host (#{@agent_user}):"
      line(@executor.quiet?("id", "-u", @agent_user), "agent user #{@agent_user} exists")
      [@runner_user, @agent_user].each do |member|
        member_ok = @executor.quiet?(
          "dseditgroup", "-o", "checkmember", "-m", member, AgentBootstrap::GROUP,
        )
        line(member_ok, "#{member} in the #{AgentBootstrap::GROUP} group")
      end
      line(File.exist?(@sudoers_path), "sudoers edge present (#{@sudoers_path})")
      line(work_tree_cooperative?, "_work tree cooperative (group #{AgentBootstrap::GROUP}, setgid)")
      line(File.directory?(@shared_root), "shared root present (#{@shared_root})")
      return unless @container_required

      line(@executor.quiet?("brew", "list", "--formula", "colima"), "colima installed (agent engine)")
    end

    # Group + setgid facts via stat, so inspection needs no privileges.
    #
    # @return [Boolean]
    sig { returns(T::Boolean) }
    def work_tree_cooperative?
      work = File.join(@runner_dir, "_work")
      return false unless File.directory?(work)

      group, perms = @executor.capture("stat", "-f", "%Sg %Sp", work).strip.split(" ", 2)
      # %Sp renders "drwxrwsr-x": type + owner triplet + group triplet —
      # setgid shows as "s" in the group execute slot, index 6.
      group == AgentBootstrap::GROUP && perms.to_s[6] == "s"
    end

    # `brew bundle check` against the org Brewfile — the same list `dev up`
    # converges; a deploymentless host has nothing to check.
    sig { void }
    def report_host_tooling
      @out.puts "Host tooling:"
      brewfile = @brewfile_path
      if brewfile.nil? || !File.exist?(brewfile)
        line(true, "no org Brewfile shipped (nothing to check)")
        return
      end

      line(
        @executor.quiet?("brew", "bundle", "check", "--file=#{brewfile}"),
        "host tooling converged (brew bundle check)",
      )
    end
  end
end

# typed: strict
# frozen_string_literal: true

require "etc"
require "stringio"

require "dev/agent_bootstrap"
require "dev/data_root"
require "dev/label_contracts"
require "dev/runner_discovery"
require "dev/runner_registry"
require "dev/settings"

module Dev
  # `dev runner status` — register's inspect-only counterpart: this
  # machine's discovered enrollments (every ~/actions-runner-*/.runner),
  # each one's labels read from GitHub (their single home — unknown when
  # offline), and the inspected reality of every agent-labeled enrollment's
  # contract. Nothing here mutates and nothing is recorded — every fact is
  # re-derived from the host or GitHub every time (plans#26: inspected,
  # never recorded). No dev.yml involved: status is the machine's view,
  # not any repo's.
  class RunnerStatus
    extend T::Sig

    # @param discovery [Dev::RunnerDiscovery] this host's enrollments
    # @param registry [#find] the GitHub-side label reader (never mutates here)
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
        discovery: Dev::RunnerDiscovery,
        registry: T.untyped,
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
    def initialize(discovery: Dev::RunnerDiscovery.new, registry: Dev::RunnerRegistry.new,
                   out: $stdout, executor: AgentBootstrap::Executor.new,
                   agent_user: AgentBootstrap::DEFAULT_AGENT_USER,
                   runner_user: T.must(Etc.getpwuid(Process.uid)).name,
                   shared_root: DataRoot::SHARED_ROOT,
                   sudoers_path: AgentBootstrap::SUDOERS_PATH,
                   brewfile_path: self.class.default_brewfile_path,
                   container_required: false)
      @discovery = discovery
      @registry = registry
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

    # Print the report: every enrollment, per-label facts, host tooling.
    #
    # @return [void]
    sig { void }
    def report
      agent_dirs = report_enrollments
      report_agent_host(agent_dirs) unless agent_dirs.empty?
      report_host_tooling
    end

    private

    # @param ok [Boolean]
    # @param description [String]
    sig { params(ok: T::Boolean, description: String).void }
    def line(ok, description)
      @out.puts "  #{ok ? "[ok]" : "[!!]"} #{description}"
    end

    # Each discovered enrollment: scope from its own .runner record (works
    # offline), labels from GitHub. Returns the dirs of enrollments whose
    # labels carry the agent contract, so the agent host section can check
    # each one's work tree.
    #
    # @return [Array<String>] agent-labeled enrollment dirs
    sig { returns(T::Array[String]) }
    def report_enrollments
      enrollments = @discovery.enrollments
      if enrollments.empty?
        @out.puts "No runners enrolled on this host (run `dev runner register`)."
        return []
      end

      enrollments.filter_map do |enrollment|
        @out.puts "Runner '#{enrollment.name}' (#{enrollment.dir}):"
        line(true, "registered: #{enrollment.scope}")
        labels = report_labels(enrollment)
        enrollment.dir if labels && LabelContracts.agent_host?(labels.join(","))
      end
    end

    # The enrollment's custom labels, read from their single home — GitHub.
    # nil when they can't be known (offline) or the runner is gone
    # server-side (a stale local dir).
    #
    # @param enrollment [Dev::RunnerDiscovery::Enrollment]
    # @return [Array<String>, nil]
    sig { params(enrollment: Dev::RunnerDiscovery::Enrollment).returns(T.nilable(T::Array[String])) }
    def report_labels(enrollment)
      runner = @registry.find(scope: enrollment.scope, name: enrollment.name)
      if runner.nil?
        line(false, "gone on GitHub — stale enrollment (re-run `dev runner register`)")
        return nil
      end

      line(true, "labels: #{runner.custom_labels.join(", ")}")
      runner.custom_labels
    rescue RunnerRegistry::QueryError => e
      line(false, "labels unknown (#{e.message})")
      nil
    end

    # Every fact the agent contract obliges, re-derived from the host.
    #
    # @param runner_dirs [Array<String>] the agent-labeled enrollment dirs
    sig { params(runner_dirs: T::Array[String]).void }
    def report_agent_host(runner_dirs)
      @out.puts "Agent host (#{@agent_user}):"
      line(@executor.quiet?("id", "-u", @agent_user), "agent user #{@agent_user} exists")
      [@runner_user, @agent_user].each do |member|
        member_ok = @executor.quiet?(
          "dseditgroup", "-o", "checkmember", "-m", member, AgentBootstrap::GROUP,
        )
        line(member_ok, "#{member} in the #{AgentBootstrap::GROUP} group")
      end
      line(File.exist?(@sudoers_path), "sudoers edge present (#{@sudoers_path})")
      runner_dirs.each do |dir|
        line(work_tree_cooperative?(dir), "_work tree cooperative in #{dir} (group #{AgentBootstrap::GROUP}, setgid)")
      end
      line(File.directory?(@shared_root), "shared root present (#{@shared_root})")
      return unless @container_required

      line(@executor.quiet?("brew", "list", "--formula", "colima"), "colima installed (agent engine)")
    end

    # Group + setgid facts via stat, so inspection needs no privileges.
    #
    # @param runner_dir [String]
    # @return [Boolean]
    sig { params(runner_dir: String).returns(T::Boolean) }
    def work_tree_cooperative?(runner_dir)
      work = File.join(runner_dir, "_work")
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

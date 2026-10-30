# typed: strict
# frozen_string_literal: true

require "date"
require "etc"
require "stringio"

require "dev/agent_bootstrap"
require "dev/data_root"
require "dev/deps/dependency"
require "dev/host_reach"
require "dev/label_contracts"
require "dev/runner_discovery"
require "dev/runner_registry"
require "dev/runner_user"
require "dev/settings"

module Dev
  # `dev runner status` — register's inspect-only counterpart: this
  # machine's discovered enrollments (every ~/actions-runner*/.runner),
  # each one's labels read from GitHub (their single home — unknown when
  # offline), and the inspected reality of every agent-labeled enrollment's
  # contract. Nothing here mutates and nothing is recorded — every fact is
  # re-derived from the host or GitHub every time (plans#26: inspected,
  # never recorded). No dev.yml involved: status is the machine's view,
  # not any repo's.
  #
  # Under the Linux host rule (dev#310, RunnerUser) the enrollments live
  # under the runner user's home and run as it: status looks there too,
  # says who each enrollment runs as (one owned by anyone else is drift),
  # and reports the host identity — the user, its gh login, and when that
  # login's token expires (a classic PAT's `github-authentication-token-
  # expiration` header; a renewal nobody is warned of is a red run a
  # year from now).
  class RunnerStatus
    extend T::Sig

    # Days of token life left under which the line turns red.
    EXPIRY_WARNING_DAYS = 30

    # The response header a classic PAT with an expiry carries.
    EXPIRATION_HEADER = T.let(/^github-authentication-token-expiration:\s*(\d{4}-\d{2}-\d{2})/i, Regexp)

    # @param discovery [Dev::RunnerDiscovery] this host's enrollments
    # @param registry [#find] the GitHub-side label reader (never mutates here)
    # @param out [IO, StringIO] report stream
    # @param executor [#quiet?, #capture] probe seam (never mutates)
    # @param agent_user [String] expected run-as user
    # @param runner_user [String] the enrolling user
    # @param shared_root [String] expected shared-root location
    # @param brew_edge [AgentBootstrap::BrewEdge, AgentBootstrap::NoBrewEdge]
    #   the brew edge register writes for this host, or why none is needed
    # @param brewfile_path [String, nil] the org Brewfile (nil when none ships)
    # @param container_required [Boolean] whether the served repo's lock pins an image
    # @param host_identity [Dev::RunnerUser, nil] the Linux host rule's user; nil elsewhere
    # @param pins [Array<Dev::Deps::Dependency>] the enclosing checkout's lock, when run in one
    # @param reach_factory [Proc] builds the reach check for an identity; injected for tests
    sig do
      params(
        discovery: Dev::RunnerDiscovery,
        registry: T.untyped,
        out: T.any(IO, StringIO),
        executor: T.untyped,
        agent_user: String,
        runner_user: String,
        shared_root: String,
        brew_edge: AgentBootstrap::BrewEdgeDecision,
        brewfile_path: T.nilable(String),
        container_required: T::Boolean,
        host_identity: T.nilable(Dev::RunnerUser),
        pins: T::Array[Deps::Dependency],
        reach_factory: T.proc.params(identity: Dev::RunnerUser).returns(T.nilable(HostReach)),
      ).void
    end
    def initialize(discovery: Dev::RunnerDiscovery.new, registry: Dev::RunnerRegistry.new,
                   out: $stdout, executor: AgentBootstrap::Executor.new,
                   agent_user: AgentBootstrap::DEFAULT_AGENT_USER,
                   runner_user: T.must(Etc.getpwuid(Process.uid)).name,
                   shared_root: DataRoot::SHARED_ROOT,
                   brew_edge: AgentBootstrap.new(agent_user: agent_user, runner_user: runner_user).brew_edge,
                   brewfile_path: self.class.default_brewfile_path,
                   container_required: false,
                   host_identity: Dev::RunnerUser.for_host,
                   pins: [],
                   reach_factory: ->(identity) { HostReach.new(identity: identity) })
      @host_identity = host_identity
      @pins = pins
      @reach_factory = reach_factory
      @discovery = T.let(host_identity ? discovery.also_under(host_identity.home) : discovery, Dev::RunnerDiscovery)
      @registry = registry
      @out = out
      @executor = executor
      @agent_user = agent_user
      @runner_user = runner_user
      @shared_root = shared_root
      @brew_edge = brew_edge
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
      report_host_reach if report_host_identity
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
        @out.puts "Runner '#{enrollment.name}' (#{enrollment.display_dir}):"
        line(true, "registered: #{enrollment.scope}")
        report_owner(enrollment)
        labels = report_labels(enrollment)
        enrollment.dir if labels && LabelContracts.agent_host?(labels.join(","))
      end
    end

    # The enrollment's custom labels and health, read from their single
    # home — GitHub. Labels nil when they can't be known (offline) or the
    # runner is gone server-side (a stale local dir). A runner GitHub
    # lists offline while this dir holds its enrollment means nothing is
    # running the registration (a stopped service, or a dir `--replace`
    # superseded) — flagged, with register as the remedy (#238).
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
      unless runner.online?
        line(false, "offline on GitHub — the registration is not being run (re-run `dev runner register`)")
      end
      runner.custom_labels
    rescue RunnerRegistry::QueryError => e
      line(false, "labels unknown (#{e.message})")
      nil
    end

    # Who the enrollment runs as — its dir's owner — against the host
    # rule. Nothing to say without a rule (a Mac).
    #
    # @param enrollment [Dev::RunnerDiscovery::Enrollment]
    sig { params(enrollment: Dev::RunnerDiscovery::Enrollment).void }
    def report_owner(enrollment)
      identity = @host_identity
      return unless identity

      if enrollment.owner == identity.name
        line(true, "runs as #{identity.name}")
      else
        line(false, "runs as #{enrollment.owner}, not #{identity.name} — drift (re-run `dev runner register`)")
      end
    end

    # The host identity: the runner user, its gh login, its token's expiry.
    #
    # @return [Boolean] whether the identity has a gh login to probe with
    sig { returns(T::Boolean) }
    def report_host_identity
      identity = @host_identity
      return false unless identity

      @out.puts "Host identity (#{identity.name}):"
      unless @executor.quiet?("id", "-u", identity.name)
        line(false, "user #{identity.name} exists (run `dev runner register`)")
        return false
      end
      line(true, "user #{identity.name} exists")
      report_toolchain(identity)
      unless @executor.quiet?(*identity.sudo_argv("gh", "auth", "status"))
        line(false, "no gh login — `#{identity.login_command}`")
        return false
      end

      login = @executor.capture(*identity.sudo_argv("gh", "api", "user", "--jq", ".login")).strip
      expires = token_expiry(identity)
      if expires.nil?
        line(true, "gh login: #{login} (token does not expire)")
      elsif expires - Date.today > EXPIRY_WARNING_DAYS
        line(true, "gh login: #{login} (token expires #{expires.iso8601})")
      else
        line(false, "gh login: #{login} (token expires #{expires.iso8601} — within #{EXPIRY_WARNING_DAYS} days; " \
                    "renew it, then `#{identity.login_command}`)")
      end
      true
    end

    # Who owns the toolchain (dev#337): jobs upgrade dev through brew, so
    # the prefix is the runner user's by rule; anyone else's is drift —
    # every job's `brew upgrade` fails, and dev stays where it is. Nothing
    # on a host without brew.
    #
    # @param identity [Dev::RunnerUser]
    # @return [void]
    sig { params(identity: Dev::RunnerUser).void }
    def report_toolchain(identity)
      prefix = identity.toolchain_roots.first
      return unless prefix

      owner = identity.toolchain_owner
      if identity.owns_toolchain?
        line(true, "toolchain: #{prefix} owned by #{identity.name}")
      else
        line(false, "toolchain: #{prefix} owned by #{owner}, not #{identity.name} — jobs cannot upgrade dev (re-run `dev runner register`)")
      end
    end

    # What the identity can read of the checkout's lock (HostReach): one
    # line per target, the grant on each miss. Nothing without a lock.
    sig { void }
    def report_host_reach
      identity = @host_identity
      return unless identity && !@pins.empty?

      reach = @reach_factory.call(identity)
      return unless reach

      @out.puts "Host reach (#{identity.name}, this checkout's lock):"
      misses = reach.check(@pins).to_h { |verdict| [verdict.target.to_s, verdict.grant] }
      HostReach.targets(@pins).each do |target|
        grant = misses[target.to_s]
        if grant
          line(false, "cannot read #{target} — #{grant}")
        else
          line(true, "can read #{target}")
        end
      end
    end

    # When the runner user's token expires, from the response header GitHub
    # sets for expiring tokens; nil for one that does not.
    #
    # @param identity [Dev::RunnerUser]
    # @return [Date, nil]
    sig { params(identity: Dev::RunnerUser).returns(T.nilable(Date)) }
    def token_expiry(identity)
      headers = @executor.capture(*identity.sudo_argv("gh", "api", "user", "-i"))
      match = EXPIRATION_HEADER.match(headers)
      match && Date.parse(T.must(match[1]))
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
      report_sudoers_edges
      runner_dirs.each do |dir|
        line(work_tree_cooperative?(dir), "_work tree cooperative in #{dir} (group #{AgentBootstrap::GROUP}, setgid)")
      end
      line(File.directory?(@shared_root), "shared root present (#{@shared_root})")
      return unless @container_required

      line(@executor.quiet?("brew", "list", "--formula", "colima"), "colima installed (container engine)")
    end

    # The two edges the sudoers drop-in grants, read the way a job exercises
    # them rather than stat'd: the drop-in is root-owned 0440, but the
    # runner → agent edge is itself the privilege that lists the agent's
    # rules without a prompt (`-n`, list-only — sudo's listpw is satisfied
    # by any NOPASSWD rule). A refusal of the first probe is the finding,
    # never a prompt, and without that edge the brew edge cannot be read.
    sig { void }
    def report_sudoers_edges
      edge = "#{@runner_user} → #{@agent_user}, #{AgentBootstrap::EDGE_TAGS.join(":")}"
      unless @executor.quiet?("sudo", "-n", "-u", @agent_user, "true")
        line(false, "runner → agent sudoers edge missing (#{edge}) — the brew edge cannot be read without it " \
                    "(run `dev runner register`)")
        return
      end

      line(true, "runner → agent sudoers edge (#{edge})")
      report_brew_edge
    end

    # The brew edge against the rules the agent's own `sudo -l` lists: the
    # rule naming the owner and ending in the brew path, carrying every tag.
    sig { void }
    def report_brew_edge
      edge = @brew_edge
      case edge
      when AgentBootstrap::NoBrewEdge
        line(true, "no brew edge needed (#{edge.reason})")
      when AgentBootstrap::BrewEdge
        grant = "#{edge.agent} may run #{edge.path} as #{edge.owner}"
        rule = brew_rule(edge)
        if rule.nil?
          line(false, "brew edge missing: #{grant} is not granted (run `dev runner register`)")
          return
        end

        missing_tags = AgentBootstrap::EDGE_TAGS.reject { |tag| rule.include?(tag) }
        if missing_tags.empty?
          line(true, "brew edge: #{grant} (#{AgentBootstrap::EDGE_TAGS.join(", ")})")
        else
          line(false, "brew edge without #{missing_tags.join(", ")}: #{grant}, but not as dev's escalation " \
                      "runs it (run `dev runner register`)")
        end
      else
        T.absurd(edge)
      end
    end

    # The agent's sudo rule granting the edge's path as its owner, if any —
    # `sudo -l` prints one as `(<owner>) <tags>: <path>`, tags in its own
    # order, so the match is on the owner and the path alone.
    #
    # @param edge [AgentBootstrap::BrewEdge]
    # @return [String, nil]
    sig { params(edge: AgentBootstrap::BrewEdge).returns(T.nilable(String)) }
    def brew_rule(edge)
      rules = @executor.capture("sudo", "-n", "-u", @agent_user, "sudo", "-n", "-l")
      rules.lines.map(&:strip).find { |rule| rule.include?("(#{edge.owner})") && rule.end_with?(edge.path) }
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

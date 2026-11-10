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
require "dev/runner_slots"
require "dev/runner_registry"
require "dev/runner_user"
require "dev/settings"
require "dev/ui"
require "dev/wsl_conf"
require "dev/wsl_runner_host"

module Dev
  # `dev runner status` — register's inspect-only counterpart: this
  # machine's discovered enrollments (every ~/actions-runner*/.runner),
  # grouped into the host's slots at each scope (dev#470: the enrollments
  # sharing a base name — how many jobs the host runs at once there —
  # with, at an org scope, the runner group and the repos it is visible
  # to), each one's labels read
  # from GitHub (their single home — unknown when offline), and the
  # inspected reality of every agent-labeled enrollment's
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
  #
  # The agent host facts are the bootstrap's own (AgentBootstrap: the
  # host's adapter, the one register converges with), read through its
  # inspection methods — so a Mac and a Linux box report the same facts
  # in the same words, each probed with its own CLIs (plans#59).
  #
  # Inside a WSL2 distro a **WSL runner host** section reports what
  # register converged there (dev#261, WslRunnerHost): systemd running, and
  # the logon keepalive task — present, holding a session, running — that
  # is the difference between a distro that autostarts and stays up and
  # one WSL stops ~20 s after the operator's last shell closes. The task
  # is read through interop, which only a login session has; without it
  # the keepalive is `{{?}}`, never a false finding.
  class RunnerStatus
    extend T::Sig

    # Days of token life left under which the line turns red.
    EXPIRY_WARNING_DAYS = 30

    # The response header a classic PAT with an expiry carries.
    EXPIRATION_HEADER = T.let(/^github-authentication-token-expiration:\s*(\d{4}-\d{2}-\d{2})/i, Regexp)

    # @param discovery [Dev::RunnerDiscovery] this host's enrollments
    # @param registry [#find, #group_of, #group_repositories] the GitHub-side reader (never mutates here)
    # @param ui [Dev::Ui] where the report is rendered: a frame per section, a note per fact
    # @param executor [#quiet?, #capture] probe seam (never mutates)
    # @param operator [String] who is running status — the account the
    #   runner-user probes are made from
    # @param host_identity [Dev::RunnerUser, nil] the Linux host rule's user; nil elsewhere
    # @param bootstrap [Dev::AgentBootstrap] the host's agent bootstrap, whose
    #   inspection methods answer the agent host facts (the runner user it
    #   names is the sudoers grantor: the host identity on Linux, the
    #   operator on a Mac)
    # @param brewfile_path [String, nil] the org Brewfile (nil when none ships)
    # @param container_required [Boolean] whether the served repo's lock pins an image
    # @param pins [Array<Dev::Deps::Dependency>] the enclosing checkout's lock, when run in one
    # @param repo [String, nil] the enclosing checkout's "owner/repo", when run in one — the
    #   repo whose access to each org scope's slots is reported
    # @param reach_factory [Proc] builds the reach check for an identity; injected for tests
    # @param wsl_runner_host [Dev::WslRunnerHost, nil] the WSL runner host's
    #   facts (dev#261); nil off WSL
    sig do
      params(
        discovery: Dev::RunnerDiscovery,
        registry: T.untyped,
        ui: Dev::Ui,
        executor: T.untyped,
        operator: String,
        host_identity: T.nilable(Dev::RunnerUser),
        bootstrap: AgentBootstrap,
        brewfile_path: T.nilable(String),
        container_required: T::Boolean,
        pins: T::Array[Deps::Dependency],
        repo: T.nilable(String),
        reach_factory: T.proc.params(identity: Dev::RunnerUser).returns(T.nilable(HostReach)),
        wsl_runner_host: T.nilable(WslRunnerHost),
      ).void
    end
    def initialize(discovery: Dev::RunnerDiscovery.new, registry: Dev::RunnerRegistry.new,
                   ui: Dev::NoUi.new, executor: AgentBootstrap::Executor.new,
                   operator: T.must(Etc.getpwuid(Process.uid)).name,
                   host_identity: Dev::RunnerUser.for_host,
                   bootstrap: LabelContracts.agent_bootstrap(executor: executor, runner_user: host_identity&.name),
                   brewfile_path: self.class.default_brewfile_path,
                   container_required: false,
                   pins: [],
                   repo: nil,
                   reach_factory: ->(identity) { HostReach.new(identity: identity) },
                   wsl_runner_host: WslRunnerHost.for_host)
      @wsl_runner_host = wsl_runner_host
      @host_identity = host_identity
      @pins = pins
      @repo = repo
      @reach_factory = reach_factory
      @discovery = T.let(host_identity ? discovery.also_under(host_identity.home) : discovery, Dev::RunnerDiscovery)
      @registry = registry
      @ui = ui
      @executor = executor
      @operator = operator
      @bootstrap = bootstrap
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

    # Render the report: a frame per section — each scope's slots with its
    # runners nested, the host identity, its reach, the agent host, the
    # host tooling — and a note per fact, carrying its glyph: `{{v}}` ok,
    # `{{x}}` a finding, `{{?}}` unknown. The terminal frames and colours
    # them; a pipe reads the same facts plain (plans#52).
    #
    # @return [void]
    sig { void }
    def report
      agent_dirs = report_enrollments
      report_host_reach if report_host_identity
      report_wsl_runner_host
      report_agent_host(agent_dirs) unless agent_dirs.empty?
      report_host_tooling
    end

    private

    # @param ok [Boolean]
    # @param description [String]
    sig { params(ok: T::Boolean, description: String).void }
    def line(ok, description)
      @ui.note("#{ok ? "{{v}}" : "{{x}}"} #{description}")
    end

    # A fact this account cannot inspect: neither ok nor a finding, so
    # neither glyph — a `{{x}}` that is wrong once is ignored when it is
    # right (dev#348). The description says how to find out.
    #
    # @param description [String]
    sig { params(description: String).void }
    def unknown(description)
      @ui.note("{{?}} #{description}")
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
        @ui.note("No runners enrolled on this host (run `dev runner register`).")
        return []
      end

      by_scope = enrollments.group_by { |enrollment| [enrollment.scope, RunnerSlots.base_of(enrollment.name)] }
      by_scope.flat_map do |(scope, base), slots|
        if slots.length > 1 || !scope.include?("/")
          report_slots(scope, base, slots) { slots.filter_map { |enrollment| report_enrollment(enrollment) } }
        else
          slots.filter_map { |enrollment| report_enrollment(enrollment) }
        end
      end
    end

    # One enrollment's frame: where it is registered, who runs it, its
    # labels. Its dir when the labels carry the agent contract.
    #
    # @param enrollment [Dev::RunnerDiscovery::Enrollment]
    # @return [String, nil]
    sig { params(enrollment: Dev::RunnerDiscovery::Enrollment).returns(T.nilable(String)) }
    def report_enrollment(enrollment)
      @ui.frame("Runner '#{enrollment.name}' (#{enrollment.display_dir})") do
        line(true, "registered: #{enrollment.scope}")
        report_owner(enrollment)
        labels = report_labels(enrollment)
        enrollment.dir if labels && LabelContracts.agent_host?(labels.join(","))
      end
    end

    # The frame for this host's slots at a scope (dev#470), the runners'
    # frames nested in it by the block: the scope
    # first, then how many jobs the host runs at once there and the
    # runners' names (the hostname, `-<n>` beyond the first), and, at an
    # org scope, who may use them: the runner group slot 1 sits in, held
    # against the group the labels oblige (ai-flow slots belong in the
    # ai-flow group, pinned to ai-flow's workflows — plans#5 H3; a group
    # the console drifted from that is a finding, register the remedy),
    # the repos the group is visible to, and — in a checkout — whether
    # that repo is among them. All read from GitHub. A lone repo-scoped
    # enrollment needs none of it (one job at a time, that repo's alone).
    #
    # @param scope [String]
    # @param base [String] slot 1's runner name
    # @param slots [Array<Dev::RunnerDiscovery::Enrollment>]
    # @param runners [Proc] reports the slots' runners inside the frame; its value is the frame's
    # @return [Array<String>] what `runners` answered
    sig do
      params(
        scope: String, base: String, slots: T::Array[Dev::RunnerDiscovery::Enrollment],
        runners: T.proc.returns(T::Array[String]),
      ).returns(T::Array[String])
    end
    def report_slots(scope, base, slots, &runners)
      naming = RunnerSlots.new(base: base, dir: T.must(slots.first).dir)
      ordered = slots.sort_by { |slot| naming.slot_of(slot.name) || 0 }
      plural = slots.length > 1
      title = "#{scope} — #{slots.length} slot#{"s" if plural} (#{slots.length} job#{"s" if plural} at once), " \
        "runner#{"s" if plural} #{ordered.map(&:name).join(", ")}"
      @ui.frame(title) do
        report_group(scope, T.must(ordered.first)) unless scope.include?("/")
        runners.call
      end
    end

    # The org scope's group facts for slot 1: which group lists it, held
    # against the contract, and who may use it.
    #
    # @param scope [String] the org
    # @param first [Dev::RunnerDiscovery::Enrollment] slot 1
    sig { params(scope: String, first: Dev::RunnerDiscovery::Enrollment).void }
    def report_group(scope, first)
      runner = @registry.find(scope: scope, name: first.name)
      return if runner.nil?

      group = @registry.group_of(org: scope, runner_id: runner.id)
      if group.nil?
        line(false, "group: none lists '#{first.name}' — re-run `dev runner register --org`")
        return
      end

      report_group_contract(group, runner)
      report_group_access(scope, group)
    rescue RunnerRegistry::QueryError => e
      line(false, "group unknown (#{e.message})")
    end

    # The group the slots sit in against the one their labels oblige.
    #
    # @param group [Dev::RunnerRegistry::Group]
    # @param runner [Dev::RunnerRegistry::Runner] slot 1
    sig { params(group: RunnerRegistry::Group, runner: RunnerRegistry::Runner).void }
    def report_group_contract(group, runner)
      contract = LabelContracts.group_for(runner.custom_labels.join(","))
      if contract.nil?
        line(true, "group: #{group.name}")
      elsif group.name != contract.name
        line(false, "group: #{group.name} — these labels belong in '#{contract.name}' (re-run `dev runner register --org`)")
      else
        drift = contract.drift(group)
        if drift.empty?
          line(true, "group: #{group.name} — pinned to #{contract.workflows.join(", ")}")
        else
          line(false, "group: #{group.name} drifted (#{drift.join("; ")}) — re-run `dev runner register --org`")
        end
      end
    end

    # Who may use the group, and whether this checkout's repo is among them.
    #
    # @param scope [String] the org
    # @param group [Dev::RunnerRegistry::Group]
    sig { params(scope: String, group: RunnerRegistry::Group).void }
    def report_group_access(scope, group)
      repo = @repo
      if !group.selected?
        line(true, "visible to every repo at #{scope}")
        line(true, "#{repo} may use these slots") if repo
        return
      end

      selected = @registry.group_repositories(org: scope, group_id: group.id).map(&:full_name)
      line(true, "visible to #{selected.empty? ? "no repo" : selected.join(", ")}")
      return unless repo

      if selected.any? { |name| name.casecmp?(repo) }
        line(true, "#{repo} may use these slots")
      else
        line(false, "#{repo} may not use these slots — run `dev runner register --org ...` from this checkout to admit it")
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
    # The login lives in the runner user's gh config, which the operator
    # cannot read (its home is traversable, not listable — gh's own
    # default), so every fact about it is asked *as* the runner user
    # (RunnerUser#probe_argv). Status never prompts (`-n`, like the
    # sudoers-edge probes): when sudo refuses the operator the login is
    # unknown, not absent — a `{{?}}` with the command that can tell, never
    # the login remedy, which would overwrite a working login if followed
    # (dev#348).
    #
    # @return [Boolean] whether the identity has a gh login to probe with
    sig { returns(T::Boolean) }
    def report_host_identity
      identity = @host_identity
      return false unless identity

      @ui.frame("Host identity (#{identity.name})") { host_identity_facts(identity) }
    end

    # The identity's facts, in order, stopping at the first that makes the
    # rest unanswerable; true when the login is usable.
    #
    # @param identity [Dev::RunnerUser]
    # @return [Boolean]
    sig { params(identity: Dev::RunnerUser).returns(T::Boolean) }
    def host_identity_facts(identity)
      unless @executor.quiet?("id", "-u", identity.name)
        line(false, "user #{identity.name} exists (run `dev runner register`)")
        return false
      end
      line(true, "user #{identity.name} exists")
      report_toolchain(identity)
      unless @executor.quiet?(*identity.probe_argv("true"))
        unknown("gh login: cannot tell as #{@operator} (sudo as #{identity.name} needs a password here) — " \
                "check with `#{identity.status_command}`")
        return false
      end
      unless @executor.quiet?(*identity.probe_argv("gh", "auth", "status"))
        line(false, "no gh login — `#{identity.login_command}`")
        return false
      end

      login = @executor.capture(*identity.probe_argv("gh", "api", "user", "--jq", ".login")).strip
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

      @ui.frame("Host reach (#{identity.name}, this checkout's lock)") do
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
    end

    # When the runner user's token expires, from the response header GitHub
    # sets for expiring tokens; nil for one that does not.
    #
    # @param identity [Dev::RunnerUser]
    # @return [Date, nil]
    sig { params(identity: Dev::RunnerUser).returns(T.nilable(Date)) }
    def token_expiry(identity)
      headers = @executor.capture(*identity.probe_argv("gh", "api", "user", "-i"))
      match = EXPIRATION_HEADER.match(headers)
      match && Date.parse(T.must(match[1]))
    end

    # The WSL runner host's facts (dev#261), re-derived: nothing off WSL.
    sig { void }
    def report_wsl_runner_host
      wsl = @wsl_runner_host
      return unless wsl

      @ui.frame("WSL runner host (#{wsl.task.distro})") { wsl_runner_host_facts(wsl) }
    end

    # systemd first (the runner service is a unit of it), then the
    # keepalive: present, holding a session, running, and the verdict —
    # does the distro autostart at logon and stay up. Each line's remedy is
    # register; the keepalive lines are `{{?}}` when this session cannot
    # ask Windows.
    #
    # @param wsl [Dev::WslRunnerHost]
    sig { params(wsl: WslRunnerHost).void }
    def wsl_runner_host_facts(wsl)
      status = wsl.status
      report_wsl_systemd(status)
      task = wsl.task
      observed = status.keepalive
      if observed.nil?
        unknown("logon keepalive '#{task.name}': cannot tell from this session (no WSL interop — a service or an " \
                "ssh login) — run `dev runner status` from a shell opened in the distro on the Windows desktop")
        return
      end

      unless observed.present
        line(false, "logon keepalive task '#{task.name}' missing — #{task.distro} does not start at logon " \
                    "(run `dev runner register`)")
        return
      end

      line(true, "logon keepalive task '#{task.name}' registered")
      if task.holds_session?(observed)
        line(true, "keepalive action holds a session (#{task.command})")
      else
        line(false, "keepalive action does not hold a session (#{observed.execute} #{observed.arguments}) — WSL stops " \
                    "#{task.distro} ~20 s after it exits (run `dev runner register`)")
      end
      if observed.running
        line(true, "keepalive task running (a held session keeps #{task.distro} up)")
      else
        line(false, "keepalive task not running — #{task.distro} stops when the last shell closes " \
                    "(run `dev runner register`, or `Start-ScheduledTask -TaskName '#{task.name}'`)")
      end
      shortfalls = task.shortfalls(observed)
      if shortfalls.empty?
        line(true, "#{task.distro} autostarts at logon and stays up")
      else
        line(false, "#{task.distro} does not autostart and stay up: #{shortfalls.join("; ")} (run `dev runner register`)")
      end
    end

    # systemd running, or why not: a wsl.conf that enables it awaits a
    # restart; one that does not awaits register.
    #
    # @param status [Dev::WslRunnerHost::Status]
    sig { params(status: WslRunnerHost::Status).void }
    def report_wsl_systemd(status)
      if status.systemd_active
        line(true, "systemd running (the runner service is a systemd unit)")
      elsif status.systemd_configured
        line(false, "systemd enabled in #{WslConf::PATH} but not running — `wsl --shutdown` from Windows, then start the distro")
      else
        line(false, "systemd not enabled in #{WslConf::PATH} — the runner service cannot be installed (run `dev runner register`)")
      end
    end

    # Every fact the agent contract obliges, re-derived from the host.
    #
    # @param runner_dirs [Array<String>] the agent-labeled enrollment dirs
    sig { params(runner_dirs: T::Array[String]).void }
    def report_agent_host(runner_dirs)
      @ui.frame("Agent host (#{@bootstrap.agent_user})") { agent_host_facts(runner_dirs) }
    end

    # The agent contract's facts, the bootstrap's inspection asked one by
    # one: the user, the group memberships, the sudoers edges, each work
    # tree, the data root's cooperative shape, and the engine where
    # required.
    #
    # @param runner_dirs [Array<String>] agent-labeled enrollment dirs
    sig { params(runner_dirs: T::Array[String]).void }
    def agent_host_facts(runner_dirs)
      agent = @bootstrap.agent_user
      group = DataRoot::GROUP
      line(@executor.quiet?("id", "-u", agent), "agent user #{agent} exists")
      [@bootstrap.runner_user, agent].each do |member|
        line(@bootstrap.group_member?(member), "#{member} in the #{group} group")
      end
      report_sudoers_edges
      runner_dirs.each do |dir|
        line(@bootstrap.work_tree_cooperative?(dir), "_work tree cooperative in #{dir} (group #{group}, setgid)")
      end
      root = @bootstrap.data_root
      line(@bootstrap.cooperative_dir?(root), "data root #{root} shared with group #{group} (setgid)")
      locks = @bootstrap.brew_locks_dir
      if locks
        line(@bootstrap.brew_locks_cooperative?,
          "brew lock dir #{locks} shared with group #{group} (setgid, locks group-writable)")
      end
      return unless @container_required

      line(@bootstrap.engine_converged?, @bootstrap.engine_fact)
    end

    # The two edges the sudoers drop-in grants, read the way a job exercises
    # them rather than stat'd: the drop-in is root-owned 0440, but the
    # runner → agent edge is itself the privilege that lists the agent's
    # rules without a prompt (`-n`, list-only — sudo's listpw is satisfied
    # by any NOPASSWD rule). A refusal of the first probe is the finding,
    # never a prompt, and without that edge the brew edge cannot be read.
    sig { void }
    def report_sudoers_edges
      agent = @bootstrap.agent_user
      edge = "#{@bootstrap.runner_user} → #{agent}, #{AgentBootstrap::EDGE_TAGS.join(":")}"
      unless @executor.quiet?("sudo", "-n", "-u", agent, "true")
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
      edge = @bootstrap.brew_edge
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
      rules = @executor.capture("sudo", "-n", "-u", @bootstrap.agent_user, "sudo", "-n", "-l")
      rules.lines.map(&:strip).find { |rule| rule.include?("(#{edge.owner})") && rule.end_with?(edge.path) }
    end

    # `brew bundle check` against the org Brewfile — the same list `dev up`
    # converges; a deploymentless host has nothing to check.
    sig { void }
    def report_host_tooling
      @ui.frame("Host tooling") { host_tooling_fact }
    end

    # Converged against the org Brewfile, or nothing to check.
    sig { void }
    def host_tooling_fact
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

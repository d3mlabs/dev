# typed: strict
# frozen_string_literal: true

require "date"
require "etc"
require "set"
require "socket"
require "stringio"

require "dev/agent_bootstrap"
require "dev/data_root"
require "dev/deps/dependency"
require "dev/host_reach"
require "dev/label_contracts"
require "dev/platform"
require "dev/reach"
require "dev/reach_fact"
require "dev/runner_discovery"
require "dev/runner_family"
require "dev/runner_registry"
require "dev/runner_role"
require "dev/runner_slots"
require "dev/runner_user"
require "dev/settings"
require "dev/ui"
require "dev/version"
require "dev/wsl_conf"
require "dev/wsl_runner_host"

module Dev
  # `dev runner status` — register's inspect-only counterpart. Nothing
  # here mutates and nothing is recorded: every fact is re-derived from
  # the host or GitHub each time. No dev.yml involved: status is the
  # machine's view, not any repo's.
  #
  # The report is framed by **subject**: the host first, then one frame
  # per **family** — this host's slots of one role at one scope
  # (RunnerFamily) — in builtin role order. Every line is a fact: a
  # subject, a property, what is expected of it and by whom (GitHub, the
  # slot's role, the host rule), what was observed, and the remedy when
  # they differ. `{{v}}` when they agree, `{{x}}` when they do not,
  # `{{?}}` when this account cannot tell.
  #
  # A family's **reach** is one fact in three clauses, read from the
  # job's side — from which repos, via which workflows, selected by
  # which labels (Reach) — computed from GitHub and held against what the
  # role obliges (ReachFact). Whether the family is registered at a repo
  # or at an org is not a frame of its own: scope only decides who fixes
  # the first clause, and the mechanism — the runner group, its
  # visibility, its pin, the repo registration — is named only as
  # evidence under a ✗.
  #
  # **Slot facts fold**: online on GitHub, service installed, who runs
  # it, and for an agent slot its `_work` tree — identical across a
  # family's slots → one line naming the slots; a slot that deviates
  # breaks out as its own ✗ line with its dir.
  #
  # The host frame holds host-level subjects only: the Linux host rule's
  # runner user (its existence, toolchain, gh login and token expiry, and
  # what that login can read of a checkout's lock), the agent host
  # (AgentBootstrap's inspection, when an agent family is enrolled), the
  # WSL runner host (WslRunnerHost, inside a WSL2 distro), and the host
  # tooling against the org Brewfile.
  #
  # After the frames, bare: in a checkout, which families that repo's
  # jobs reach; then the posture — slots, facts, drifted.
  class RunnerStatus
    extend T::Sig

    # Days of token life left under which the line turns red.
    EXPIRY_WARNING_DAYS = 30

    # The response header a classic PAT with an expiry carries.
    EXPIRATION_HEADER = T.let(/^github-authentication-token-expiration:\s*(\d{4}-\d{2}-\d{2})/i, Regexp)

    # What runs the runner service on each OS, named in the host frame.
    SERVICE_MANAGERS = T.let({ "darwin" => "launchd", "linux" => "systemd" }.freeze, T::Hash[String, String])

    # The hanging indent of a reach fact's second and third clauses: the
    # width of the glyph, its space, and `reach: `.
    CLAUSE_INDENT = T.let(" " * "✓ reach: ".length, String)

    # Slot suffixes `-2 … -N` collapse from this many consecutive ones.
    SUFFIX_RUN_COLLAPSE = 3

    # @param discovery [Dev::RunnerDiscovery] this host's enrollments
    # @param registry [#find, #group_of, #group_repositories, #repository] the GitHub-side reader (never mutates here)
    # @param ui [Dev::Ui] where the report is rendered: a frame per subject, a note per fact
    # @param executor [#quiet?, #capture] probe seam (never mutates)
    # @param operator [String] who is running status — the account the
    #   runner-user probes are made from
    # @param host [String] this machine's name, the host frame's title
    # @param host_os [String] "darwin" / "linux" / "windows"
    # @param host_identity [Dev::RunnerUser, nil] the Linux host rule's user; nil elsewhere
    # @param bootstrap [Dev::AgentBootstrap] the host's agent bootstrap, whose
    #   inspection methods answer the agent host facts (the runner user it
    #   names is the sudoers grantor: the host identity on Linux, the
    #   operator on a Mac — and the user every slot is expected to run as)
    # @param brewfile_path [String, nil] the org Brewfile (nil when none ships)
    # @param container_required [Boolean] whether the served repo's lock pins an image
    # @param pins [Array<Dev::Deps::Dependency>] the enclosing checkout's lock, when run in one
    # @param repo [String, nil] the enclosing checkout's "owner/repo", when run in one — the
    #   repo whose jobs the invocation line says which families reach
    # @param reach_factory [Proc] builds the host reach check for an identity; injected for tests
    # @param wsl_runner_host [Dev::WslRunnerHost, nil] the WSL runner host's
    #   facts; nil off WSL
    sig do
      params(
        discovery: Dev::RunnerDiscovery,
        registry: T.untyped,
        ui: Dev::Ui,
        executor: T.untyped,
        operator: String,
        host: String,
        host_os: String,
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
                   host: Socket.gethostname,
                   host_os: Platform.os,
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
      @host = host
      @host_os = host_os
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
      @facts = T.let(0, Integer)
      @drifted = T.let(0, Integer)
      @reaches = T.let({}, T::Hash[RunnerFamily, Reach])
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

    # Render the report: the host's frame, a frame per family, then the
    # invocation and posture lines bare. The terminal frames and colours
    # them; a pipe reads the same facts plain.
    #
    # @return [void]
    sig { void }
    def report
      families = RunnerFamily.of(@discovery.enrollments.map { |enrollment| slot_of(enrollment) })
      report_host(families)
      shared_roles = families.map { |family| family.role.name }.tally.select { |_name, count| count > 1 }.keys
      families.each { |family| report_family(family, scoped: shared_roles.include?(family.role.name)) }
      @ui.note("No runners enrolled on this host (run `dev runner register`).") if families.empty?
      report_invocation(families)
      slots = families.sum { |family| family.slots.length }
      @ui.note("posture: #{plural(slots, "slot")} · #{plural(@facts, "fact")} · #{@drifted} drifted")
    end

    private

    # One fact: counted, and a drift when not ok.
    #
    # @param ok [Boolean]
    # @param description [String]
    sig { params(ok: T::Boolean, description: String).void }
    def line(ok, description)
      @facts += 1
      @drifted += 1 unless ok
      @ui.note("#{ok ? "{{v}}" : "{{x}}"} #{description}")
    end

    # A fact this account cannot inspect: neither ok nor a finding, so
    # neither glyph — a `{{x}}` that is wrong once is ignored when it is
    # right. The description says how to find out.
    #
    # @param description [String]
    sig { params(description: String).void }
    def unknown(description)
      @facts += 1
      @ui.note("{{?}} #{description}")
    end

    # A continuation of the fact above it, under the hanging indent.
    #
    # @param text [String]
    sig { params(text: String).void }
    def clause(text)
      @ui.note("#{CLAUSE_INDENT}#{text}")
    end

    # @param count [Integer]
    # @param noun [String]
    # @return [String] "1 slot", "3 slots"
    sig { params(count: Integer, noun: String).returns(String) }
    def plural(count, noun)
      "#{count} #{noun}#{"s" unless count == 1}"
    end

    # --- slots and families ------------------------------------------------

    # An enrollment with GitHub's record of it: the runner, nil when
    # GitHub has lost it, and the error when GitHub could not be asked.
    #
    # @param enrollment [Dev::RunnerDiscovery::Enrollment]
    # @return [Dev::RunnerFamily::Slot]
    sig { params(enrollment: RunnerDiscovery::Enrollment).returns(RunnerFamily::Slot) }
    def slot_of(enrollment)
      runner = @registry.find(scope: enrollment.scope, name: enrollment.name)
      RunnerFamily::Slot.new(enrollment: enrollment, runner: runner, query_error: nil)
    rescue RunnerRegistry::QueryError => e
      RunnerFamily::Slot.new(enrollment: enrollment, runner: nil, query_error: e.message)
    end

    # One family's frame: its reach, then its slots. The title names the
    # scope when the host plays the role at more than one — the Mac's org
    # agent pool beside cellbound-3d's own slot — and is the bare role
    # otherwise.
    #
    # @param family [Dev::RunnerFamily]
    # @param scoped [Boolean] whether another family of the same role is on the host
    sig { params(family: RunnerFamily, scoped: T::Boolean).void }
    def report_family(family, scoped:)
      title = "#{family.role.name} · #{plural(family.slots.length, "slot")}"
      title += " · #{family.scope}" if scoped
      @ui.frame(title) do
        report_reach(family)
        report_slots(family)
      end
    end

    # --- reach ---------------------------------------------------------------

    # The family's reach fact, or why there is none: GitHub unreachable,
    # every slot lost, an org slot no group lists.
    #
    # @param family [Dev::RunnerFamily]
    sig { params(family: RunnerFamily).void }
    def report_reach(family)
      first = family.first_listed
      if first.nil?
        error = family.query_error
        if error
          unknown("reach: cannot tell — #{error}")
        else
          line(false, "reach: none — GitHub lists no slot of this family (stale enrollments; re-run `dev runner register`)")
        end
        return
      end

      fact = reach_fact(family, T.must(first.runner))
      if fact.nil?
        line(false, "reach: none — no org group at #{family.org} lists #{first.enrollment.name} (#{remedy(family)})")
        return
      end

      @reaches[family] = fact.observed
      render_reach(fact, family)
    rescue RunnerRegistry::QueryError => e
      unknown("reach: cannot tell — #{e.message}")
    end

    # GitHub's reach for the family held against the role's. nil when an
    # org slot sits in no group (nothing fixes its reach).
    #
    # @param family [Dev::RunnerFamily]
    # @param runner [Dev::RunnerRegistry::Runner] the first listed slot's record
    # @return [Dev::ReachFact, nil]
    # @raise [RunnerRegistry::QueryError]
    sig { params(family: RunnerFamily, runner: RunnerRegistry::Runner).returns(T.nilable(ReachFact)) }
    def reach_fact(family, runner)
      labels = Set.new(runner.custom_labels)
      unless family.org_scoped?
        observed = Reach.new(repos: Set[family.scope], workflows: Reach::ANY, labels: labels)
        target = Reach::Target.new(repo: family.scope, public: @registry.repository(family.scope).public?, org_scoped: false)
        return compare_reach(family.role, target, observed, ReachFact::RepoRegistration.new(repo: family.scope))
      end

      group = @registry.group_of(org: family.scope, runner_id: runner.id)
      return nil if group.nil?

      repos = group.selected? ? Set.new(@registry.group_repositories(org: family.scope, group_id: group.id).map(&:full_name)) : Reach::ALL
      workflows = group.restricted_to_workflows ? Set.new(group.selected_workflows) : Reach::ANY
      observed = Reach.new(repos: repos, workflows: workflows, labels: labels)
      target = Reach::Target.new(repo: org_target_repo(family, observed), public: false, org_scoped: true)
      compare_reach(family.role, target, observed, ReachFact::GroupPlacement.new(group: group))
    end

    # The role's expectation for the target against GitHub's reach — or
    # the role's refusal of the target, as a fact of its own.
    #
    # @param role [Dev::RunnerRole]
    # @param target [Dev::Reach::Target]
    # @param observed [Dev::Reach]
    # @param fixed_by [ReachFact::RepoRegistration, ReachFact::GroupPlacement]
    # @return [Dev::ReachFact]
    sig { params(role: RunnerRole, target: Reach::Target, observed: Reach, fixed_by: ReachFact::Provenance).returns(ReachFact) }
    def compare_reach(role, target, observed, fixed_by)
      ReachFact.compare(expected: role.expected_reach(target), observed: observed, fixed_by: fixed_by)
    rescue Reach::ExposedError => e
      ReachFact.exposed(exposure: e.message, observed: observed, fixed_by: fixed_by)
    end

    # The repo an org family's expectation is phrased for. An org
    # registration ran from one or more checkouts nothing recorded, and a
    # role's expectation names the target only to say *a selection* —
    # ReachFact compares that clause by shape — so any admitted repo
    # stands in: this checkout's when it is one, else the first selected,
    # else the org (an open group names no repo at all).
    #
    # @param family [Dev::RunnerFamily]
    # @param observed [Dev::Reach]
    # @return [String]
    sig { params(family: RunnerFamily, observed: Reach).returns(String) }
    def org_target_repo(family, observed)
      repo = @repo
      return repo if repo && observed.admits?(repo)

      selected = observed.open? ? [] : T.cast(observed.repos, T::Set[String]).to_a
      selected.first || family.org
    end

    # The fact's three clauses — the first on the glyph line, the rest
    # under the hanging indent — each naming what the role expects where
    # it drifts, then the mechanism and remedy as evidence under a ✗.
    #
    # @param fact [Dev::ReachFact]
    # @param family [Dev::RunnerFamily]
    sig { params(fact: ReachFact, family: RunnerFamily).void }
    def render_reach(fact, family)
      drift = fact.drift
      expected = fact.expected
      role = family.role.name
      from = "jobs from #{repos_clause(fact.observed, family)}"
      from += " — the #{role} role expects #{expected.open? ? "every repo" : "a selection"}" if expected && drift.include?(:repos)
      line(fact.ok?, "reach: #{from}")

      via = "via #{workflows_clause(fact.observed.workflows)}"
      via += " — the #{role} role expects #{workflows_clause(expected.workflows)}" if expected && drift.include?(:workflows)
      clause(via)

      runs_on = "runs-on #{labels_clause(fact.observed.labels)}"
      runs_on += " — the #{role} role expects #{labels_clause(expected.labels)}" if expected && drift.include?(:labels)
      clause(runs_on)

      exposure = fact.exposure
      clause("exposed: #{exposure}") if exposure
      return if fact.ok?

      # The exposure sentence carries its own advice; a drift gets the
      # register run that converges it.
      cause = "cause: #{fact.fixed_by.evidence}"
      cause += " — #{remedy(family)}" unless drift.empty?
      clause(cause)
    end

    # @param observed [Dev::Reach]
    # @param family [Dev::RunnerFamily]
    # @return [String] "every d3mlabs repo", "no repo", or the selection, this checkout's repo bold
    sig { params(observed: Reach, family: RunnerFamily).returns(String) }
    def repos_clause(observed, family)
      return "every #{family.org} repo" if observed.open?

      repos = T.cast(observed.repos, T::Set[String]).sort
      return "no repo" if repos.empty?

      repos.map { |name| name.casecmp?(@repo.to_s) ? "{{bold:#{name}}}" : name }.join(", ")
    end

    # @param workflows [Symbol, Set<String>]
    # @return [String] "any workflow", "no workflow", or the pins, `only`
    sig { params(workflows: T.any(Symbol, T::Set[String])).returns(String) }
    def workflows_clause(workflows)
      return "any workflow" if workflows == Reach::ANY

      pins = T.cast(workflows, T::Set[String])
      return "no workflow (restricted to none)" if pins.empty?

      "#{pins.map { |workflow| short_workflow(workflow) }.join(", ")} only"
    end

    # `owner/repo/.github/workflows/<file>@refs/heads/<branch>` as
    # `owner/repo/<file>@<branch>`: the parts GitHub's spelling fixes
    # dropped, the rest kept.
    #
    # @param workflow [String]
    # @return [String]
    sig { params(workflow: String).returns(String) }
    def short_workflow(workflow)
      path, ref = workflow.split("@", 2)
      short = path.to_s.sub("/.github/workflows/", "/")
      ref ? "#{short}@#{ref.delete_prefix("refs/heads/")}" : short
    end

    # @param labels [Set<String>]
    # @return [String]
    sig { params(labels: T::Set[String]).returns(String) }
    def labels_clause(labels)
      labels.empty? ? "no label" : labels.to_a.join(" | ")
    end

    # The register run that converges the family's reach: at the org for a
    # pinned role's org family, at the repo for everything else — a build
    # host found at the org included, since the role's reach is the repo
    # registration's.
    #
    # @param family [Dev::RunnerFamily]
    # @return [String]
    sig { params(family: RunnerFamily).returns(String) }
    def remedy(family)
      role = family.role
      flag = role.build_host? ? "" : " --role #{role.name}"
      at_org = family.org_scoped? && role.org_scoped?
      where = at_org ? "a checkout at #{family.org}" : "the repo's checkout"
      "re-run `dev runner register#{flag}` from #{where}"
    end

    # --- slots ---------------------------------------------------------------

    # Each slot's facts folded: slots whose facts read the same share one
    # line naming them; a slot that deviates is its own ✗ line, its dir
    # beside its name.
    #
    # @param family [Dev::RunnerFamily]
    sig { params(family: RunnerFamily).void }
    def report_slots(family)
      family.slots.group_by { |slot| slot_verdict(slot, family) }.each do |(ok, text), slots|
        case ok
        when true then line(true, "#{slot_names(slots)} — #{text}")
        when false then line(false, "#{slot_names(slots, dirs: true)} — #{text}")
        else unknown("#{slot_names(slots)} — #{text}")
        end
      end
    end

    # One slot's facts as a verdict: `[true, …]` when every fact holds,
    # `[false, …]` naming each finding with the remedy, `[nil, …]` when
    # GitHub's half could not be read.
    #
    # @param slot [Dev::RunnerFamily::Slot]
    # @param family [Dev::RunnerFamily]
    # @return [Array] the verdict and its text
    sig { params(slot: RunnerFamily::Slot, family: RunnerFamily).returns([T.nilable(T::Boolean), String]) }
    def slot_verdict(slot, family)
      held = []
      findings = []
      unknowns = []
      github_facts(slot, family, held, findings, unknowns)
      enrollment = slot.enrollment
      enrollment.service_installed ? held << "service installed" : findings << "no service installed"
      runner_user = @host_identity&.name || @bootstrap.runner_user
      enrollment.owner == runner_user ? held << "runs as #{runner_user}" : findings << "runs as #{enrollment.owner}, not #{runner_user}"
      if family.role.name == RunnerRole::AGENT_NAME
        group = DataRoot::GROUP
        if @bootstrap.work_tree_cooperative?(enrollment.dir)
          held << "_work shared with group #{group}"
        else
          findings << "_work tree not cooperative (group #{group}, setgid)"
        end
      end

      return [false, "#{findings.join("; ")} (re-run `dev runner register`)"] unless findings.empty?
      return [nil, (held + unknowns).join(" · ")] unless unknowns.empty?

      [true, held.join(" · ")]
    end

    # What GitHub says of the slot: online, and labels as the role's. A
    # runner GitHub lists offline while this dir holds its enrollment
    # means nothing is running the registration (a stopped service, or a
    # dir `--replace` superseded); one GitHub has lost is a stale dir.
    #
    # @param slot [Dev::RunnerFamily::Slot]
    # @param family [Dev::RunnerFamily]
    # @param held [Array<String>] facts that hold, appended to
    # @param findings [Array<String>] facts that do not, appended to
    # @param unknowns [Array<String>] facts GitHub could not answer, appended to
    sig do
      params(slot: RunnerFamily::Slot, family: RunnerFamily, held: T::Array[String], findings: T::Array[String], unknowns: T::Array[String]).void
    end
    def github_facts(slot, family, held, findings, unknowns)
      runner = slot.runner
      if runner.nil?
        error = slot.query_error
        error ? unknowns << "GitHub unreachable (#{error})" : findings << "gone on GitHub — stale enrollment"
        return
      end

      runner.online? ? held << "online" : findings << "offline on GitHub — the registration is not being run"
      expected = Set.new(family.role.labels)
      return if Set.new(runner.custom_labels) == expected

      findings << "labels #{labels_clause(Set.new(runner.custom_labels))}, not the role's #{labels_clause(expected)}"
    end

    # The slots' names, the first in full and the rest as their `-<n>`
    # suffix where they share its base; a run of consecutive suffixes
    # collapses to its ends (`-2 … -10`). With `dirs:`, each name carries
    # its dir — the evidence a ✗ line needs.
    #
    # @param slots [Array<Dev::RunnerFamily::Slot>]
    # @param dirs [Boolean]
    # @return [String]
    sig { params(slots: T::Array[RunnerFamily::Slot], dirs: T::Boolean).returns(String) }
    def slot_names(slots, dirs: false)
      return slots.map { |slot| "#{slot.enrollment.name} (#{slot.enrollment.display_dir})" }.join(", ") if dirs

      names = slots.map { |slot| slot.enrollment.name }
      first = T.must(names.first)
      base = RunnerSlots.base_of(first)
      rest = names.drop(1)
      return names.join(", ") unless rest.all? { |name| name.start_with?("#{base}-") }

      suffixes = rest.map { |name| name.delete_prefix(base) }
      numbers = slots.drop(1).map(&:number)
      consecutive = numbers.length >= SUFFIX_RUN_COLLAPSE && numbers.each_cons(2).all? { |pair| pair.fetch(1) == pair.fetch(0) + 1 }
      return "#{first}, #{suffixes.first} … #{suffixes.last}" if consecutive

      [first, *suffixes].join(", ")
    end

    # --- the invocation ------------------------------------------------------

    # In a checkout: which families that repo's jobs reach, by the reach
    # GitHub fixes — or none, with register as the remedy. Nothing outside
    # a checkout.
    #
    # @param families [Array<Dev::RunnerFamily>]
    sig { params(families: T::Array[RunnerFamily]).void }
    def report_invocation(families)
      repo = @repo
      return unless repo

      reached = families.select { |family| @reaches[family]&.admits?(repo) }.map { |family| family.role.name }.uniq
      if reached.empty?
        line(false, "this checkout (#{repo}) reaches no family — run `dev runner register` from this checkout")
      else
        @ui.note("this checkout (#{repo}) reaches: #{reached.join(", ")}")
      end
    end

    # --- the host ------------------------------------------------------------

    # The host's frame: the Linux host rule's identity and what it can
    # read, the agent host when an agent family is enrolled, the WSL
    # runner host inside a distro, the tooling.
    #
    # @param families [Array<Dev::RunnerFamily>]
    sig { params(families: T::Array[RunnerFamily]).void }
    def report_host(families)
      manager = SERVICE_MANAGERS.fetch(@host_os, "no service manager")
      @ui.frame("#{@host} · #{@host_os} · #{manager}") do
        report_host_reach if report_host_identity
        agent_host_facts if families.any? { |family| family.role.name == RunnerRole::AGENT_NAME }
        wsl = @wsl_runner_host
        wsl_runner_host_facts(wsl) if wsl
        host_tooling_fact
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
    # the login remedy, which would overwrite a working login if
    # followed. Nothing without a host rule (a Mac).
    #
    # @return [Boolean] whether the identity has a gh login to probe with
    sig { returns(T::Boolean) }
    def report_host_identity
      identity = @host_identity
      return false unless identity

      unless @executor.quiet?("id", "-u", identity.name)
        line(false, "runner user #{identity.name} missing (run `dev runner register`)")
        return false
      end
      line(true, "runner user #{identity.name} exists")
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

    # Who owns the toolchain: jobs upgrade dev through brew, so
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

      misses = reach.check(@pins).to_h { |verdict| [verdict.target.to_s, verdict.grant] }
      HostReach.targets(@pins).each do |target|
        grant = misses[target.to_s]
        if grant
          line(false, "#{identity.name} cannot read #{target} (this checkout's lock) — #{grant}")
        else
          line(true, "#{identity.name} can read #{target} (this checkout's lock)")
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

    # The WSL runner host's facts, re-derived: systemd first (the runner
    # service is a unit of it), then the keepalive: present, holding a
    # session, running, and the verdict — does the distro autostart at
    # logon and stay up. Each line's remedy is register; the keepalive
    # lines are `{{?}}` when this session cannot ask Windows.
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

    # The agent host's facts, the bootstrap's inspection asked one by one:
    # the user, the group memberships, the sudoers edge (and that no brew
    # edge sits beside it), the data root's cooperative shape, brew's lock
    # dir, and the engine where required.
    # The `_work` trees are the agent slots' own facts, in their family.
    sig { void }
    def agent_host_facts
      agent = @bootstrap.agent_user
      group = DataRoot::GROUP
      line(@executor.quiet?("id", "-u", agent), "agent user #{agent} exists")
      [@bootstrap.runner_user, agent].each do |member|
        line(@bootstrap.group_member?(member), "#{member} in the #{group} group")
      end
      report_sudoers_edges
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

    # The sudoers edge and the agent's own rules, read the way a job
    # exercises them rather than stat'd: the drop-in is root-owned 0440,
    # but the runner → agent edge is itself the privilege that lists the
    # agent's rules without a prompt (`-n`, list-only — sudo's listpw is
    # satisfied by any NOPASSWD rule). A refusal of the first probe is the
    # finding, never a prompt, and without that edge the agent's rules
    # cannot be read.
    sig { void }
    def report_sudoers_edges
      agent = @bootstrap.agent_user
      edge = "#{@bootstrap.runner_user} → #{agent}, #{AgentBootstrap::EDGE_TAGS.join(":")}"
      unless @executor.quiet?("sudo", "-n", "-u", agent, "true")
        line(false, "runner → agent sudoers edge missing (#{edge}) — the agent's rules cannot be read without it " \
                    "(run `dev runner register`)")
        return
      end

      line(true, "runner → agent sudoers edge (#{edge})")
      report_brew_edge
    end

    # No brew edge is the converged state (AgentBootstrap::NO_BREW_EDGE);
    # a rule in the agent's own `sudo -l` that runs brew as anyone is
    # drift — a drop-in from before the edge was retired — which the next
    # register rewrites away.
    sig { void }
    def report_brew_edge
      reason = @bootstrap.brew_edge.reason
      granted = brew_rules
      if granted.empty?
        line(true, "no brew edge (#{reason})")
      else
        line(false, "brew edge present — #{@bootstrap.agent_user} may run brew as another user (#{granted.join("; ")}): " \
                    "#{reason} (run `dev runner register` to retire it)")
      end
    end

    # The agent's sudo rules that run brew, if any — `sudo -l` prints one
    # as `(<owner>) <tags>: <path>`, so a rule is matched on its command's
    # name alone: the owner and the path are whatever the drop-in that
    # wrote it said, a symlink's realpath included.
    #
    # @return [Array<String>]
    sig { returns(T::Array[String]) }
    def brew_rules
      rules = @executor.capture("sudo", "-n", "-u", @bootstrap.agent_user, "sudo", "-n", "-l")
      rules.lines.map(&:strip).select { |rule| File.basename(rule.split.last.to_s) == "brew" }
    end

    # `brew bundle check` against the org Brewfile — the same list `dev up`
    # converges; a deploymentless host has nothing to check.
    sig { void }
    def host_tooling_fact
      brewfile = @brewfile_path
      if brewfile.nil? || !File.exist?(brewfile)
        line(true, "no org Brewfile shipped (nothing to check)")
        return
      end

      version = Dev::Version.current
      if @executor.quiet?("brew", "bundle", "check", "--file=#{brewfile}")
        line(true, "host tooling matches #{brewfile} (dev #{version})")
      else
        line(false, "host tooling drifted from #{brewfile} (dev #{version}) — run `dev up`")
      end
    end
  end
end

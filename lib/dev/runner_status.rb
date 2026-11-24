# typed: strict
# frozen_string_literal: true

require "date"
require "etc"
require "set"
require "socket"
require "stringio"

require "dev/data_root"
require "dev/deps/dependency"
require "dev/host_reach"
require "dev/job_identity"
require "dev/job_identity/darwin"
require "dev/job_identity/linux"
require "dev/platform"
require "dev/reach"
require "dev/reach_fact"
require "dev/retired_job_hook"
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
require "dev/wsl_host"
require "dev/wsl_runner_host"

module Dev
  # `dev runner status` — register's inspect-only counterpart. Nothing
  # here mutates and nothing is recorded: every fact is re-derived from
  # the host or GitHub each time. Status is the machine's view; the
  # enclosing checkout's dev.yml lends only its role declarations (and
  # the one-release aliases, RunnerRoleAliases), so a slot of a role
  # declared there is held against that role. A slot of a role no
  # declaration at hand names is known by its pool (RunnerRole.pooled):
  # its reach is read and shown, not verified.
  #
  # The report is framed by **subject**: the host first, then one frame
  # per **family** — this host's slots of one role at one scope
  # (RunnerFamily) — roles by name, the build host last. Every line is a fact: a
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
  # it, no job-started hook left from dev 0.9.x (RetiredJobHook), and for
  # a slot whose role has a job identity its `_work` tree — identical across a
  # family's slots → one line naming the slots; a slot that deviates
  # breaks out as its own ✗ line with its dir.
  #
  # The host frame holds host-level subjects only: the Linux host rule's
  # runner user (its existence, toolchain, gh login and token expiry, and
  # what that login can read of a checkout's lock), each job identity
  # (JobIdentity's inspection, when a family of a role with one is
  # enrolled or the user is on the host), the
  # WSL runner host (WslRunnerHost, inside a WSL2 distro), and the host
  # tooling against the org Brewfile.
  #
  # After the frames, bare: in a checkout, which families that repo's
  # jobs reach; then the posture — slots, facts, drifted.
  #
  # `--check` (#check) is the host frame and the posture alone, GitHub
  # not asked: what a job runs on its own identity after every `dev up`,
  # so a host whose posture is behind the running dev's contract goes red
  # in the job rather than waiting for a human's `status`. Posture stays
  # register's to converge — a job inspects it and refuses to be quiet.
  class RunnerStatus
    extend T::Sig

    # `--check` found red facts. The ledger above names each with its
    # remedy; the message sums them. A RuntimeError so the CLI boundary
    # prints it and exits 1 — the job's step goes red, the run log holds
    # the ledger.
    class PostureDriftError < RuntimeError; end

    # Why a slot has no GitHub record under `--check`: not lost — not asked.
    NOT_ASKED = "not asked (--check reads the host alone)"

    # Days of token life left under which the line turns red.
    EXPIRY_WARNING_DAYS = 30

    # The response header a classic PAT with an expiry carries.
    EXPIRATION_HEADER = T.let(/^github-authentication-token-expiration:\s*(\d{4}-\d{2}-\d{2})/i, Regexp)

    # What runs the runner service on each OS, named in the host frame.
    SERVICE_MANAGERS = T.let({ "darwin" => "launchd", "linux" => "systemd" }.freeze, T::Hash[String, String])

    # The hanging indent of a reach fact's second and third clauses: the
    # width of the glyph, its space, and `reach: `.
    CLAUSE_INDENT = T.let(" " * "✓ reach: ".length, String)

    # The indent of a family's own line after its slot facts: the width
    # of the glyph and its space, so it reads under the facts' text.
    FACT_INDENT = T.let(" " * "✓ ".length, String)

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
    # @param roles [Hash{String => Dev::RunnerRole}] the roles declared at hand, by name:
    #   the enclosing checkout's dev.yml roles bound to it, and the aliases
    # @param identity_factory [Proc] builds the job identity for a user, whose
    #   inspection methods answer that identity's host facts; injected for tests
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
        roles: T::Hash[String, RunnerRole],
        identity_factory: T.proc.params(user: String).returns(JobIdentity),
        brewfile_path: T.nilable(String),
        container_required: T::Boolean,
        pins: T::Array[Deps::Dependency],
        repo: T.nilable(String),
        reach_factory: T.proc.params(identity: Dev::RunnerUser).returns(T.nilable(HostReach)),
        wsl_runner_host: T.nilable(WslRunnerHost),
      ).void
    end
    def initialize(discovery: Dev::RunnerDiscovery.new, registry: Dev::RunnerRegistry.new,
                   ui: Dev::NoUi.new, executor: JobIdentity::Executor.new,
                   operator: T.must(Etc.getpwuid(Process.uid)).name,
                   host: Socket.gethostname,
                   host_os: Platform.os,
                   host_identity: Dev::RunnerUser.for_host,
                   roles: {},
                   identity_factory: ->(user) { JobIdentity.for_host(user: user, runner_user: host_identity&.name, executor: executor) },
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
      @roles = roles
      @identity_factory = identity_factory
      @identities = T.let({}, T::Hash[String, JobIdentity])
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
      families = RunnerFamily.of(@discovery.enrollments.map { |enrollment| slot_of(enrollment) }, declared: @roles)
      report_host(families)
      families.each { |family| report_family(family) }
      @ui.note("No runners enrolled on this host (run `dev runner register`).") if families.empty?
      report_invocation(families)
      report_posture(families)
    end

    # `--check`: the host's frame, then the posture — today's host against
    # today's contract, nothing recorded and GitHub not asked. The family
    # frames are skipped: reach, online, labels and group need the org
    # token and are the human's `dev runner status`. Which roles are
    # enrolled is read from the records' pools (RunnerFamily::Slot#role,
    # as for a slot GitHub has lost), so an org family of a declared role
    # still brings its job identity's facts in; a repo-scoped one names
    # no pool, and the identity's user on the host stands in for it
    # (#job_identity_facts). Fast and token-free, so every job runs it on
    # its own identity, and a red fact is the exit status.
    #
    # @return [void]
    # @raise [PostureDriftError] when any fact is red
    sig { void }
    def check
      slots = @discovery.enrollments.map do |enrollment|
        RunnerFamily::Slot.new(enrollment: enrollment, runner: nil, query_error: NOT_ASKED)
      end
      families = RunnerFamily.of(slots, declared: @roles)
      report_host(families)
      report_posture(families)
      return if @drifted.zero?

      raise PostureDriftError,
        "host posture: #{@drifted} of #{plural(@facts, "fact")} drifted — the red lines above name each remedy " \
        "(`dev runner register` converges the host; `dev up` the tooling)"
    end

    private

    # The sum of the run: how many slots this host holds, how many facts
    # were inspected, how many drifted.
    #
    # @param families [Array<Dev::RunnerFamily>]
    sig { params(families: T::Array[RunnerFamily]).void }
    def report_posture(families)
      slots = families.sum { |family| family.slots.length }
      @ui.note("posture: #{plural(slots, "slot")} · #{plural(@facts, "fact")} · #{@drifted} drifted")
    end

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

    # One family's frame: its reach, then its slots. The title ends with
    # the scope — `agent · 3 slots · d3mlabs` — because the scope is what
    # `dev runner unregister` takes and nothing else on screen says it:
    # the slot dirs are named from history (an org slot in a repo-named
    # dir), and a lone family has no sibling to be told apart from.
    #
    # @param family [Dev::RunnerFamily]
    sig { params(family: RunnerFamily).void }
    def report_family(family)
      @ui.frame("#{family.role.name} · #{plural(family.slots.length, "slot")} · #{family.scope}") do
        report_reach(family)
        report_slots(family)
      end
    end

    # --- reach ---------------------------------------------------------------

    # The family's reach fact, or why there is none: GitHub unreachable,
    # every slot lost, an org slot no group lists. A family known by its
    # pool alone has its reach read, not held against anything.
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

    # GitHub's reach for the family held against the role's — unverified
    # for a role known by its pool alone (no declaration at hand obliges
    # anything). nil when an org slot sits in no group (nothing fixes its
    # reach).
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
      placement = ReachFact::GroupPlacement.new(group: group)
      return ReachFact.unverified(observed: observed, fixed_by: placement) if family.role.pooled?

      target = Reach::Target.new(repo: org_target_repo(family, observed), public: false, org_scoped: true)
      compare_reach(family.role, target, observed, placement)
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
    # it drifts, then the mechanism and remedy as evidence under a ✗. An
    # unverified fact reads `{{?}}`: the clauses as GitHub has them, and
    # where the declaration that could judge them is.
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
      if fact.unverified?
        unknown("reach: #{from} — unverified: no declaration of a role in group `#{role}` at hand " \
                "(run `dev runner status` from the checkout whose dev.yml declares it)")
      else
        line(fact.ok?, "reach: #{from}")
      end

      via = "via #{workflows_clause(fact.observed.workflows)}"
      via += " — the #{role} role expects #{workflows_clause(expected.workflows)}" if expected && drift.include?(:workflows)
      clause(via)

      runs_on = "runs-on #{labels_clause(fact.observed.labels)}"
      runs_on += " — the #{role} role expects #{labels_clause(expected.labels)}" if expected && drift.include?(:labels)
      clause(runs_on)

      exposure = fact.exposure
      clause("exposed: #{exposure}") if exposure
      return if fact.ok? || fact.unverified?

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

    # `owner/repo/.github/workflows/<file>@refs/tags/<tag>` (or
    # `@refs/heads/<branch>`) as `owner/repo/<file>@<tag>`: the parts
    # GitHub's spelling fixes dropped, the rest kept.
    #
    # @param workflow [String]
    # @return [String]
    sig { params(workflow: String).returns(String) }
    def short_workflow(workflow)
      path, ref = workflow.split("@", 2)
      short = path.to_s.sub("/.github/workflows/", "/")
      ref ? "#{short}@#{ref.delete_prefix("refs/heads/").delete_prefix("refs/tags/")}" : short
    end

    # @param labels [Set<String>]
    # @return [String]
    sig { params(labels: T::Set[String]).returns(String) }
    def labels_clause(labels)
      labels.empty? ? "no label" : labels.to_a.join(" | ")
    end

    # The register run that converges the family's reach: `--org` from a
    # checkout at the org for a pinned role's org family, the repo's
    # checkout for everything else — a build host found at the org
    # included, since the role's reach is the repo registration's. A
    # family known by its pool alone is the declaring checkout's to
    # converge, whichever that is.
    #
    # @param family [Dev::RunnerFamily]
    # @return [String]
    sig { params(family: RunnerFamily).returns(String) }
    def remedy(family)
      role = family.role
      if role.pooled?
        return "re-run `dev runner register --org --role <role>` from the checkout whose dev.yml declares the role in group `#{role.name}`"
      end

      flags = []
      flags << "--org" if family.org_scoped? && role.org_scoped?
      flags << "--role #{role.name}" unless role.build_host?
      argv = (["dev runner register"] + flags).join(" ")
      # A declared role is re-registered from the checkout that declares
      # it (its pins are that project's); a referenced one from the
      # checkout that references it (the lane is that repo's); a build
      # host from its repo's.
      where = if role.build_host?
        "the repo's checkout"
      elsif role.referenced?
        "the checkout whose dev.yml references #{role.name}"
      else
        "the checkout whose dev.yml declares #{role.name}"
      end
      "re-run `#{argv}` from #{where}"
    end

    # --- slots ---------------------------------------------------------------

    # Each slot's facts folded: slots whose facts read the same share one
    # line naming them; a slot that deviates is its own ✗ line, its dir
    # beside its name and its remedy. When every slot is red the family
    # adds the one command that retires it whole — a red slot is as
    # likely a slot to retire as one to repair, and the scope is the
    # argument nothing else on the line names.
    #
    # @param family [Dev::RunnerFamily]
    sig { params(family: RunnerFamily).void }
    def report_slots(family)
      verdicts = family.slots.group_by { |slot| slot_verdict(slot, family) }
      verdicts.each do |(ok, text), slots|
        case ok
        when true then line(true, "#{slot_names(slots)} — #{text}")
        when false then line(false, "#{slot_names(slots, dirs: true)} — #{text} (#{slot_remedy(slots)})")
        else unknown("#{slot_names(slots)} — #{text}")
        end
      end
      return unless verdicts.keys.all? { |ok, _text| ok == false }

      @ui.note("#{FACT_INDENT}every slot red — `dev runner unregister #{family.scope}` retires the family")
    end

    # A red slot line's remedy: register repairs, unregister with the
    # slot's dir — the exact argument — retires. Several slots folded
    # into one line each get their own unregister.
    #
    # @param slots [Array<Dev::RunnerFamily::Slot>] the red slots of one line
    # @return [String]
    sig { params(slots: T::Array[RunnerFamily::Slot]).returns(String) }
    def slot_remedy(slots)
      retire = slots.map { |slot| "`dev runner unregister #{slot.enrollment.display_dir}`" }.join(", ")
      "re-run `dev runner register` to repair, or #{retire} to retire #{slots.length == 1 ? "it" : "them"}"
    end

    # One slot's facts as a verdict: `[true, …]` when every fact holds,
    # `[false, …]` naming each finding (the remedy is the line's,
    # slot_remedy), `[nil, …]` when GitHub's half could not be read.
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
      runner_user = runner_user_name
      enrollment.owner == runner_user ? held << "runs as #{runner_user}" : findings << "runs as #{enrollment.owner}, not #{runner_user}"
      retired_hook_fact(enrollment, findings)
      job_identity = family.role.job_identity
      if job_identity
        group = DataRoot::GROUP
        if identity_for(job_identity).work_tree_cooperative?(enrollment.dir)
          held << "_work shared with group #{group}"
        else
          findings << "_work tree not cooperative (group #{group}, setgid)"
        end
      end

      return [false, findings.join("; ")] unless findings.empty?
      return [nil, (held + unknowns).join(" · ")] unless unknowns.empty?

      [true, held.join(" · ")]
    end

    # A job-started hook dev 0.9.x left in the slot's dir is drift: no
    # slot's jobs run a head a hook installed anymore — what a job runs
    # is its checkout's lock, installed by the job's own `dev up` — and
    # the next register removes it (RetiredJobHook). Nothing is held when
    # there is none: that is every slot's steady state.
    #
    # @param enrollment [Dev::RunnerDiscovery::Enrollment]
    # @param findings [Array<String>] facts that do not hold, appended to
    sig { params(enrollment: RunnerDiscovery::Enrollment, findings: T::Array[String]).void }
    def retired_hook_fact(enrollment, findings)
      return unless RetiredJobHook.present?(enrollment.dir)

      findings << "job-started hook left from dev 0.9.x (#{RetiredJobHook::SCRIPT}) — jobs run the checkout's lock, not a head"
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
    # read, each job identity the host carries, the WSL runner host
    # inside a distro, the tooling.
    #
    # @param families [Array<Dev::RunnerFamily>]
    sig { params(families: T::Array[RunnerFamily]).void }
    def report_host(families)
      manager = SERVICE_MANAGERS.fetch(@host_os, "no service manager")
      @ui.frame("#{@host} · #{@host_os} · #{manager}") do
        report_host_reach if report_host_identity
        job_identity_facts(families)
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
    # taken. Nothing without a host rule (a Mac).
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
    # lines are `{{?}}` when this session cannot ask Windows — and the
    # task is named only after that check, since a session without
    # interop (a job under the runner's service) has no distro name to
    # build it from either.
    #
    # @param wsl [Dev::WslRunnerHost]
    sig { params(wsl: WslRunnerHost).void }
    def wsl_runner_host_facts(wsl)
      status = wsl.status
      report_wsl_systemd(status)
      observed = status.keepalive
      if observed.nil?
        unknown("logon keepalive#{wsl_task_name(wsl)}: cannot tell from this session (no WSL interop — a service or an " \
                "ssh login) — run `dev runner status` from a shell opened in the distro on the Windows desktop")
        return
      end

      task = wsl.task
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

    # The keepalive's name for the unknown line, ` 'Start-WSL-<distro>-Runner'`
    # — or nothing when the session does not name its distro (WSL's /init
    # sets WSL_DISTRO_NAME for a login session, never for a service).
    #
    # @param wsl [Dev::WslRunnerHost]
    # @return [String]
    sig { params(wsl: WslRunnerHost).returns(String) }
    def wsl_task_name(wsl)
      " '#{wsl.task.name}'"
    rescue WslHost::DistroUnknownError
      ""
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

    # The user every slot is expected to run as, and the sudoers grantor
    # of every job identity: the host rule's user on Linux, the operator
    # on a Mac (the runner service is a per-user LaunchAgent).
    #
    # @return [String]
    sig { returns(String) }
    def runner_user_name
      @host_identity&.name || @operator
    end

    # The job identity for a user, built once per run.
    #
    # @param user [String]
    # @return [Dev::JobIdentity]
    sig { params(user: String).returns(JobIdentity) }
    def identity_for(user)
      @identities[user] ||= @identity_factory.call(user)
    end

    # Each job identity's facts, its inspection asked one by one: the
    # user, the group memberships, the sudoers edge (and that no brew
    # edge sits beside it), the data root's cooperative shape, brew's lock
    # dir, and the engine where required. The `_work` trees are the
    # slots' own facts, in their family.
    #
    # A host carries a job identity when a family of a role with one is
    # enrolled on it, or when the user of one the declarations at hand
    # name is on it: register creates that user for the role alone, so
    # its presence says the host was converged for it — what tells under
    # `--check`, where GitHub is not asked and a repo-scoped family's
    # record names no pool. Nothing on any other host.
    #
    # @param families [Array<Dev::RunnerFamily>] this host's families
    sig { params(families: T::Array[RunnerFamily]).void }
    def job_identity_facts(families)
      enrolled = families.filter_map { |family| family.role.job_identity }.uniq
      declared = @roles.values.filter_map(&:job_identity)
      (enrolled + declared).uniq.each do |user|
        exists = @executor.quiet?("id", "-u", user)
        next unless enrolled.include?(user) || exists

        report_job_identity(identity_for(user), exists)
      end
    end

    # One job identity's facts.
    #
    # @param identity [Dev::JobIdentity]
    # @param exists [Boolean] whether its user is on the host
    sig { params(identity: JobIdentity, exists: T::Boolean).void }
    def report_job_identity(identity, exists)
      group = DataRoot::GROUP
      line(exists, "job identity #{identity.user} exists")
      [identity.runner_user, identity.user].each do |member|
        line(identity.group_member?(member), "#{member} in the #{group} group")
      end
      report_sudoers_edges(identity)
      root = identity.data_root
      line(identity.cooperative_dir?(root), "data root #{root} shared with group #{group} (setgid)")
      locks = identity.brew_locks_dir
      if locks
        line(identity.brew_locks_cooperative?,
          "brew lock dir #{locks} shared with group #{group} (setgid, locks group-writable)")
      end
      return unless @container_required

      line(identity.engine_converged?, identity.engine_fact)
    end

    # The sudoers edge and the identity's own rules, read the way a job
    # exercises them rather than stat'd: the drop-in is root-owned 0440,
    # but the runner → identity edge is itself the privilege that lists
    # the identity's rules without a prompt (`-n`, list-only — sudo's
    # listpw is satisfied by any NOPASSWD rule). A refusal of the first
    # probe is the finding, never a prompt, and without that edge the
    # identity's rules cannot be read.
    #
    # @param identity [Dev::JobIdentity]
    sig { params(identity: JobIdentity).void }
    def report_sudoers_edges(identity)
      user = identity.user
      edge = "#{identity.runner_user} → #{user}, #{JobIdentity::EDGE_TAGS.join(":")}"
      unless @executor.quiet?("sudo", "-n", "-u", user, "true")
        line(false, "runner → #{user} sudoers edge missing (#{edge}) — #{user}'s rules cannot be read without it " \
                    "(run `dev runner register`)")
        return
      end

      line(true, "runner → #{user} sudoers edge (#{edge})")
      report_brew_edge(identity)
    end

    # No brew edge is the converged state (JobIdentity::NO_BREW_EDGE); a
    # rule in the identity's own `sudo -l` that runs brew as anyone is
    # drift — a drop-in from before the edge was retired — which the next
    # register rewrites away.
    #
    # @param identity [Dev::JobIdentity]
    sig { params(identity: JobIdentity).void }
    def report_brew_edge(identity)
      reason = identity.brew_edge.reason
      granted = brew_rules(identity.user)
      if granted.empty?
        line(true, "no brew edge (#{reason})")
      else
        line(false, "brew edge present — #{identity.user} may run brew as another user (#{granted.join("; ")}): " \
                    "#{reason} (run `dev runner register` to retire it)")
      end
    end

    # The user's sudo rules that run brew, if any — `sudo -l` prints one
    # as `(<owner>) <tags>: <path>`, so a rule is matched on its command's
    # name alone: the owner and the path are whatever the drop-in that
    # wrote it said, a symlink's realpath included.
    #
    # @param user [String]
    # @return [Array<String>]
    sig { params(user: String).returns(T::Array[String]) }
    def brew_rules(user)
      rules = @executor.capture("sudo", "-n", "-u", user, "sudo", "-n", "-l")
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
        line(false, "host tooling behind #{brewfile} (dev #{version}) — #{host_tooling_remedy}")
      end
    end

    # The `dev up` that converges the host half: brew is single-owner, so
    # it is the prefix owner's (HostService skips the layer for anyone
    # else). The reader's own on a Mac, on a host not handed over, or in a
    # job that runs as the runner user; as the runner user, outside any
    # checkout, once the prefix is its — spelled with the name the host
    # resolves, not the rule's default.
    #
    # @return [String]
    sig { returns(String) }
    def host_tooling_remedy
      identity = @host_identity
      return "run `dev up`" unless identity && identity.toolchain_owner == identity.name && identity.name != @operator

      "`#{identity.host_up_command}` (outside a checkout)"
    end
  end
end

# Runners

`dev runner` enrolls a machine as a GitHub Actions self-hosted runner and
converges everything the jobs landing on it will need. This page also
covers how each kind of build host — workstation, box, hosted runner —
gets warm.

## dev runner

```bash
dev runner register                       # this repo's build host: repo scope, label = the repo name
dev runner register --labels ue-engine    # a build host with custom labels
dev runner register --org --role agent    # the org agent host (--ai-flow is the same)
dev runner register --org --role agent --slots 3        # three jobs at once
dev runner register --ai-flow --slots 2   # this repo's own agent slots
dev runner register --org --role orchestrator --slots 8 # the orchestrator pool
dev runner register --role ue-farm        # a role this repo's dev.yml declares
dev runner register --org --labels ue-engine --group ue-hosted # org pool in a human-made group
dev runner status                         # this machine's enrollments and host facts
dev runner status --check                 # the host's posture alone, no GitHub; exit 1 on drift (every job runs it)
dev runner unregister d3mlabs             # by scope (the last part of a family's title in status) …
dev runner unregister ~/actions-runner    # … or by directory (Tab completes both)
dev runner unregister                     # lists this host's enrollments by scope and asks which
```

Enrollment is a machine fact, not a repo one: nothing is recorded in
`dev.yml` or any inventory file. Labels live on GitHub; the scope and the
runner group live in the runner directory's own `.runner` record. `dev
runner status` reads both back.

### Roles

A registration declares the **role** its runners play. The labels, the
runner group, the scope, the runner name and the directory all derive from
it.

| Role | Labels | Group | Scope |
|---|---|---|---|
| `agent` (`--role agent`, or `--ai-flow`) | `ai-ask ai-edit ai-split ai-build ai-learn` | `ai-flow`, pinned to ai-flow's workflows | org |
| `orchestrator` (`--role orchestrator`, or `--labels ai-orchestrator`) | `ai-orchestrator` | `ai-orchestrator`, pinned, open to every repo | org |
| build host (bare `register`, or `--labels`) | the repo's name, or the `--labels` set | none, or `--group` | repo; `--org` with `--labels` makes an org pool |
| a dev.yml role (`--role <name>`) | as declared | none | repo |

A repo declares its own roles in `dev.yml`:

```yaml
runner_roles:
  ue-farm:
    labels: [ue, gpu]
```

A dev.yml role carries a name and labels only. It may not take a builtin's
name or an ai-flow label. `--role x` that nothing declares is refused, as
is `--role x --labels y` (the role's labels are its declaration) and
`--org` with a dev.yml role.

### Scope

Scope follows the checkout. Without `--org`, the slots are the repo's:
only that repo's jobs land on them, for every role — a build host, or a
repo that wants agent slots of its own. `--org` registers at the repo's
org: an agent or orchestrator joins its pinned runner group there, and
every repo the group admits may send jobs; `--org --labels <set>` makes a
custom set an org pool. A **build host** is the repo-scoped default: use
one when a repo needs its own hardware or its own concurrency cap — a
repo whose jobs hold the one Unreal editor enrolls one build host and has
concurrency 1 by construction.

A repo owned by a **user account** is registered at the repo whatever the
role. A user account has no runner groups, so there is no org to register
at; `--org` is refused there.

Scope fixes the first clause of a family's reach. A registration at the
org lets a group fix which repos and which workflows reach the slots; a
registration at a repo fixes the repos to that one and leaves the
workflows open, whatever the role.

Any role registered at a **public** repo is refused. A repo-scoped
runner takes jobs from any of the repo's workflows, and on a public repo
that includes an approved fork PR's — a workflow file the fork's author
wrote. Only an org runner group can pin which workflows reach a runner,
so a public repo's runners must be org-scoped, in a pinned group.

What a registration gets, by the repo's owner and visibility:

| | Private repo | Public repo |
|---|---|---|
| **Organization** | Any role at the repo (the default); a pinned role at the org, in its group (`--org`) | A pinned role at the org, in its group (`--org`). Repo scope refused |
| **User account** | Any role at the repo | Refused: no runner groups exist to pin with. Move the repo into an organization, or run its jobs on GitHub-hosted runners (ai-flow's hosted-runner mode, [ai-flow#142](https://github.com/d3mlabs/ai-flow/issues/142)) |

ai-flow adopters: its README's *Choosing your runner setup* says which
runners ai-flow needs in each case and what else the public case requires.

GitHub routes a job to any online runner visible to the repo whose labels
cover the job's `runs-on`. There is no repo-beats-org priority, so an org
host and a repo-scoped runner sharing a label pool their capacity.

### Labels

Workflows demand labels (`runs-on: [self-hosted, <label>]`); enrollments
supply them. Three vocabularies:

- **A repo's own label**: its name as GitHub spells it, lowercased
  (`d3mlabs/cellbound-3d` → `cellbound-3d`). Bare `dev runner register`
  uses it; `--repo a/b` moves it.
- **Custom labels** through `--labels`, for special fleets (`ue-engine`).
- **The ai-flow vocabulary**: `--ai-flow` enrolls the agent set (`ai-ask
  ai-edit ai-split ai-build ai-learn`, one per slash command) in the
  `ai-flow` runner group. `ai-orchestrator` is separate: the host
  `/build --split`'s orchestrator runs on, which polls for hours and
  belongs on an always-on box with many cheap slots, never on an agent
  slot. A `--labels` set mixing the two is refused.

A capability label is an obligation: `register` converges what each label
requires. A plain target-host label converges nothing; the agent labels
run the [agent host bootstrap](#agent-hosts).

### Slots and names

A runner runs one job at a time. `--slots N` enrolls N runners —
`<name>`, `<name>-2`, … — each with its own directory and service and the
same labels. Re-running without `--slots` keeps the size it finds; a
smaller number lists the surplus and asks before retiring it. `dev runner
status` reports a family as one header per scope (`d3mlabs — 3 slots`).

A **family** is the runners one host enrolls in one role at one scope. A
host plays each role at most once per scope; registering the same role
again amends the family it finds. One host may hold several families at
one org scope (the agent set beside the orchestrator pool), and
`register` sizes and retires only the family it was asked for.

Runner names are `<hostname>-<role>` for grouped and dev.yml roles
(`mac1-agent`, `mac1-agent-2`, `mac1-orchestrator`) and the bare hostname
for a build host; directories are `~/actions-runner-<role>[-n]`. A family
that is already enrolled keeps the names it has; `--name` and `--dir`
override slot 1's. Which role an enrollment plays is read from its labels
on GitHub, or, for an enrollment GitHub has lost, from the runner group
its `.runner` record names — never from its name or directory.

### Runner groups

A runner group says which repos may use an org host's slots. Labels say
what a host can do, slots how many jobs it runs at once, the group who may
send them.

- The `agent` role sits in the `ai-flow` group. `register` creates it when
  the org lacks it — visibility *selected*, restricted to ai-flow's two
  reusable workflows — and re-converges it when the console drifted.
- The `orchestrator` role sits in the `ai-orchestrator` group, visibility
  *all*.
- `--group <name>` is for human-made pools of build hosts; the group must
  already exist.

Admission is derived from the checkout: `dev runner register --org …` run
in a repo (or with `--repo a/b`) admits that repo to the slots' group. Run
it once per adopting repo.

**A public repository may only use a group restricted to workflows**; a
fork's pull request could otherwise run arbitrary code on the host.
Admitting a public repo to an unpinned group is refused.

A repo's build host carries the repo's own label, which no org runner
advertises, so its jobs never pool with the org's.

### The enrolled runner

Bare `dev runner register` makes the repo's **enrolled runner**: repo
scope, the repo's name as label. The lifecycle verbs dispatch to it from a
machine that is not a build's environment when nothing else is named
(`--runner <label>`, then the `lifecycle.runner` setting, then the
enrolled runner, then the project's container). "Available" is read from
the Actions API each time: a runner at the repo's scope with that label,
online. Busy counts; offline does not. See
[Lifecycle](lifecycle.md#dispatch-resolution).

### What register does

1. **The engine**, when the checkout pins an `image`: the same step as
   `dev up`'s, sized from this repo's `engine:` hint
   ([Containers](containers.md#engine-resources)).
2. **Platform facts**: the Linux [runner user](#linux-the-runner-user),
   the [WSL2 keepalive](#wsl2), the [agent host](#agent-hosts) when agent
   labels are advertised.
3. **The enrollment.** An existing enrollment at the scope has its labels
   amended in place on GitHub; re-running is the no-op and the drift
   repair. Only a scope nothing serves gets the full ceremony: download,
   registration token through your `gh` auth, `config.sh --unattended`,
   service install. A repo-scoped runner re-registered `--org`
   deregisters at its old scope first.

Register never takes over another runner's registration. Runner names are
unique per scope; a name held by a registration that is not this family's
own is refused, naming the holder — pass `--name` to enroll beside it.

Two states make register stop and ask before enrolling fresh (`--yes`
answers; headless the answer is no, and the by-hand `dev runner
unregister <dir>` lines are printed): more than one local enrollment for
the scope, or GitHub listing the runner offline.

Flags: `--role`, `--org`, `--repo`, `--ai-flow`, `--slots`, `--group`,
`--yes`, `--labels`, `--dir`, `--name`, `--agent-user`, `--as` (the Linux
runner user's name). `--org` needs no checkout; bare register does.

### Linux: the runner user

On Linux the enrollment belongs to a dedicated user, `runner` by default
(`--as <user>` renames it), with no sudo, no password and no access to
your home. The runner user owns the enrollment directory, the service's
identity, and the `gh` login jobs fetch private dependencies with; you
mint the registration token and install the service unit. A job never runs
with your credentials.

Nothing records the name. Register hands brew's prefix to the runner
user, so a host whose prefix belongs to a user other than you is a host
whose runner user is that user: register, `dev runner status` and
`register --help` read the name from the prefix's owner, and every
by-hand command they print spells it. The examples below say `runner`;
on a host registered `--as ci` they read `ci`.

Before enrolling, register converges in one sudo session: the shared
[data root](data-root.md#the-linux-root-is-shared), the runner user (in
groups `docker` and `dev`), Homebrew's shellenv in
`/etc/profile.d/linuxbrew.sh`, brew's prefix handed to the runner user
(jobs upgrade dev through brew, and brew has one owner), and the
deployment tap trusted by the runner user and by you (brew's trust is per
user, and your own `dev up` reads the tap's formulae as you).

Then register logs the runner user in to gh. At a terminal it asks for a
**machine user's** token — a dedicated account with read access to what the
jobs fetch, never an admin's — and hands it to `gh auth login
--with-token` on stdin; dev never stores it. Headless it prints the command
and stops: `sudo -iu runner gh auth login --with-token`.

With a checkout, register checks the runner user can reach every `gh` pin's
repo and every image's floor package, and refuses to enroll while one is
unreachable, printing the grant to make. `dev runner status` reports the
same as host facts.

After the handover, package work by hand on that host is `sudo -iu runner
brew …`. Your own `dev up` in a checkout there does two different things
with brew. The host half — dev's self-update and the org Brewfile — is
skipped: it is host state the jobs converge on their next run. In a
checkout the skip is silent; outside one, `dev up`'s summary says so
and names the owner (`dev: host layer converged — brew tooling is
runner's and was skipped (jobs converge it; by hand: sudo -iu runner dev
up)`), so a `dev up` run to upgrade dev never reads as success over a
self-update that did not run. To converge it by hand — to test a
release before the next job, or to repair the box — run `dev up` as the
prefix's owner, outside any checkout: `sudo -iu runner dev up`, the
command `dev runner status` prints on its host tooling line when the
host is behind. `dev up` is the upgrade — brew's update and the scoped
upgrade of dev itself — so there is no `brew upgrade` to type. The
checkout's pins (`dependencies.rb`) are project state nobody converges
for you, so your own `dev up` installs them through the runner user's
brew, asking your password once (`sudo -u runner <prefix>/bin/brew …`);
no sudoers line is written for it — a sudoer gains nothing from one, and
dev builds no new grant. Without a terminal the same write runs `sudo -n`
and a refusal is reported, never prompted for. An enrollment owned by
anyone but the runner user is drift and is re-enrolled as the runner user
on the next `dev runner register`.

Macs have no runner user: the service is your LaunchAgent.

### WSL2

A WSL2 distro stops ~20 s after its last client session ends, and systemd
units inside are not sessions, so after a reboot nothing starts the
runner. Inside a WSL2 distro register also converges:

- a **logon keepalive** — a Task Scheduler task,
  `Start-WSL-<distro>-Runner`, that holds a client session
  (`conhost.exe --headless wsl.exe -d <distro> -u root -- sleep infinity`)
  with no time limit;
- **systemd** in `/etc/wsl.conf`;
- the **`.wslconfig` ratchet** for the checkout's `engine:` hint.

These need Windows interop, which only a shell opened on the Windows
desktop has; from a service or an ssh login register refuses and says
where to run. Enabling systemd or growing the VM needs `wsl --shutdown`
from Windows, then `dev runner register` again, then
`Start-ScheduledTask -TaskName 'Start-WSL-<distro>-Runner'` (or a log off
and on) to bring the distro back under the keepalive. `dev runner status`
reports all of this in the host frame.

### Agent hosts

Agent labels (`ai-ask`, `ai-build`, …) mark the host as one that runs an
AI agent in jobs. Register converges, idempotently and with admin
prompts:

- a non-admin **agent user**, `ai-agent` (`--agent-user` renames it), with
  its own home and no sudo;
- the **`dev` group** with both the runner identity and the agent in it;
- one **sudoers edge**: runner user → agent (`NOPASSWD:SETENV`), so the
  service spawns the agent. There is no edge back: the agent writes no
  brew prefix — pins are converged dispatcher-side before the agent
  spawns, gems land in a home the agent owns — and a brew write as the
  prefix owner would be arbitrary code as that user (on Linux, a
  docker-group user). A drop-in still carrying the older agent → owner
  brew edge is rewritten without it, and `dev runner status` reports such
  an edge as drift;
- the shared **data root** (provisioned on a Mac and, when an existing
  root is not what `dev runner status` inspects — group `dev`, setgid,
  group-writable throughout — re-granted tree and all; asserted on
  Linux), brew's lock directory as a group space, and the deployment tap
  trusted by the agent user;
- on a Mac, the agent's own **colima** engine when the repo pins an
  image. On Linux there is no agent engine: the agent for an image-built
  repo runs inside the project's container, and until that lands a Linux
  host refuses to serve agent labels for such a repo;
- after enrollment, the `_work` tree as a group space, and the **runner
  service environment**: umask 002, `AI_FLOW_AGENT_USER`,
  `AI_FLOW_AGENT_GROUP`, `AI_FLOW_RUNNER_SLOT`.

Last, warn-only, whether the agent CLI (`cursor-agent`) is installed in
the brew prefix. It arrives through the org Brewfile on the prefix owner's
`dev up` — yours on a Mac, `sudo -iu runner dev up` on Linux.

### dev runner status

The machine's view, framed by subject at a terminal and plain through a
pipe: one frame for the **host**, then one per **role family** — this
host's slots sharing a scope and a role, the title ending with the scope
(`agent · 3 slots · d3mlabs`, `agent · 1 slot · d3mlabs/cellbound-3d`,
`build-host · 1 slot · JPDuchesne/snappy`). The scope is the argument
`dev runner unregister` takes, and the title is the one place that says
it: a slot's directory is named from its history, not its scope. Every
line is a fact with a verdict (`✓`, `✗`, or `?` when GitHub could not be
asked), and the box and a Mac render the same shape.

The host frame carries what is true of the machine regardless of its
slots: the runner user and its gh login with the token's expiry, who owns
the toolchain, whether that identity can read this checkout's lock
(every `gh` pin's repo, every image's floor package), the agent host's
contract when the host is one — an agent family enrolled, or the agent
user on the host (agent user, group memberships, the sudoers edge and the
absence of a brew edge, data root, brew locks, engine), the WSL keepalive and
systemd facts inside a distro, and host tooling against the org Brewfile.

Each family frame opens with its **reach** — what GitHub lets this
family's slots run, compared with what the role expects — as one fact in
three clauses:

```text
orchestrator · 2 slots · d3mlabs
✓ reach: jobs from every d3mlabs repo
         via d3mlabs/ai-flow/ai-commands.yml@main, d3mlabs/ai-flow/origin-firing.yml@main only
         runs-on ai-orchestrator
✓ box-orchestrator, -2 — online · service installed · runs as runner
```

The mechanism behind the reach — the group's name, its visibility, its
workflow pins, a repo registration — is not a fact of its own: it is
printed only under a ✗, as the `cause:` line, with the remedy when a
clause drifted (`re-run dev runner register --org --role agent from a
checkout at d3mlabs`). A build host sitting in the unpinned `Default` group and an
agent family whose group lost the ai-flow pin each render that way; a
registration at a public repo renders as `exposed:` with the cause and no
remedy, since the exposure sentence says what to do. Slot facts (online,
service installed, who it runs as, the `_work` grant for agents) fold into
one line while uniform, and a deviating slot breaks out on its own ✗ line
with its directory and the findings. A red slot's remedy names both ways
out — `re-run dev runner register to repair, or dev runner unregister
<dir> to retire it` — since a slot offline on GitHub is as likely one
nobody wants anymore as one to repair; when every slot of a family is
red, the family adds `dev runner unregister <scope> retires the family`.

After the frames, in a checkout, `this checkout (owner/repo) reaches: …`
names the families whose reach admits that repo, and
`posture: N slots · M facts · K drifted` sums the run.

#### --check

`dev runner status --check` prints the host frame and the posture line
alone and exits 1 when any fact is red. It is what a job runs after `dev
up` — ai-flow's dispatch job does, and puts the drift in the command's
reply — so a host whose posture is behind the running dev's contract goes
red in the next run's log rather than waiting for someone to run `status`.
Posture stays `register`'s to converge (users, sudoers, ownership need
root, and the runner user has no sudo); a job inspects it and refuses to
be quiet.

What `--check` reads is today's host against today's contract — no stamp,
no version file — and nothing GitHub would have to be asked for: the
runner user and its login, the toolchain's owner, the agent host's
contract (agent user, group memberships, the sudoers edge and the absence
of a brew edge, data root, brew locks), the WSL systemd and keepalive
facts, host tooling against the org Brewfile. The family frames — reach,
online, labels, the runner group — need the org token and stay the
human's `dev runner status`. Which roles are enrolled is read from each
enrollment's own `.runner` record (its runner group), as for a slot GitHub
has lost; a repo-scoped agent family records no group, so the agent user's
presence on the host is what brings the agent host's facts in there. Run
as the job's own identity, facts that identity cannot probe read `?`, not
`✗` — the runner user's gh login from a job that cannot sudo, the
keepalive from a service without interop — and only a `✗` fails the
check. Each red line names its remedy; most are `re-run dev runner
register`; the tooling line's is `dev up` as the prefix's owner —
`sudo -iu runner dev up` (outside a checkout) when that is the runner
user and the reader is not, `dev up` when the reader owns the prefix (a
Mac, a job running as the runner user).

A job nobody picks up sits at *Waiting for a runner to pick up this job…*
under a `Requested labels:` line, the same whether the runners are busy,
offline, in a group that does not admit the repo, or never enrolled; it is
cancelled after 24 hours. Check the job's labels against the org's Runners
page: an idle runner carrying every one of them, in a group that admits
the repo.

### dev runner unregister

```bash
dev runner unregister [<scope> | <dir>] [--yes]
```

Names an enrollment by scope (`d3mlabs`, `JPDuchesne/snappy` — every slot
this host has there) or by directory (one slot). The scope is the last
part of the family's frame title in `dev runner status` (`agent · 3 slots
· d3mlabs`); a directory's name says nothing reliable about its scope.
With no argument it lists this host's enrollments grouped by scope and
asks which scope or directory — the same candidates Tab completes;
`--yes` with no argument is refused, since a yes names nothing. It asks,
then stops and uninstalls the service, removes the registration with a
token minted at the enrollment's scope, and clears the enrollment files.
The runner binaries stay, so a later `register --dir` reuses the
download.

## Build hosts, cold to warm

`dev up` satisfies the lock against the host's data root and installs the
difference. The host's job is to bring a data root to the start line.

| Setup | What persists the data root | Cold | Warm |
|---|---|---|---|
| **Host provisioned from the environment's image** (a cloud worker or WSL distro baked from it) | its disk | `dev up` installs the whole lock on the host; no container | `dev up` is a probe |
| **Linux host not provisioned from it** (the box, a stock hosted runner) | its disk, at `/var/lib/dev` | `dev up` creates the root, converges docker, pulls the image, installs the lock, starts the container over the host's own root | probe on both sides |
| **Mac** | the Mac's disk, and named volumes in the colima VM for the container | `dev up` installs the darwin lock on the host, then the Linux lock inside the container's volumes | probe on both sides |
| **Self-hosted runner** (a box) | its disk | Homebrew + dev, `gh auth login`, `dev runner register` | `d3mlabs/dev/up` upgrades dev and probes; several branches stay warm at once; `dev cache gc --keep N` per job trims |
| **Hosted runner** (GitHub larger runner) | a **checkpoint**: a custom runner image of the disk after `dev up` | `d3mlabs/dev/up` installs Homebrew + dev, then the full lock — minutes to tens of minutes | boots the checkpoint; `d3mlabs/dev/up` is a probe |

### The hosted recipe

A job converges the runner it landed on with one step, the same on a
GitHub-hosted runner and on a self-hosted box:

```yaml
steps:
  - uses: actions/checkout@v4
  - uses: d3mlabs/dev/up@main
  # the project's commands
```

The step takes no inputs. Everything it needs to know about the project
is in the checkout: `dev.yml` and the lock. It runs, in order:

1. **Install Homebrew + dev**, each when the host lacks it: the Homebrew
   installer when no `brew` is on PATH or at a standard prefix; then `brew
   tap d3mlabs/d3mlabs`, `brew trust --tap d3mlabs/d3mlabs` and `brew
   install d3mlabs/d3mlabs/dev` when the prefix has no dev. Homebrew loads
   no formula from a tap its user has not trusted, and the trust prompt
   dies on a non-interactive runner, so the trust comes before the
   install. A host that already carries both — a checkpoint, a box —
   skips this step.
2. **Upgrade dev**: `brew update`, then `brew upgrade d3mlabs/d3mlabs/dev`.
   A dev release reaches every runner on its next job; a no-op when dev is
   current.
3. **Check the toolchain**: `dev` and `gh` on PATH, and `gh auth token`
   answering. A missing credential fails the job here, named, rather than
   partway through provisioning.
4. **`dev up`**: the host half (the data root, the org tooling) and the
   project half (the lock, the project's own `up:`). A cold runner
   provisions; a warm one probes and returns in seconds.

The job supplies gh's credential. On a hosted runner that is `GH_TOKEN` in
the job's `env`, a token that can read every private pin the lock names.
On a box it is the [runner user's gh login](#linux-the-runner-user), and
the job sets nothing.

#### Which verb: `dev up` or `dev deps install`

Two kinds of identity run dev inside a job, and each has one verb.

**A job's own identity runs `dev up`.** The runner user — on a hosted
runner or on a self-hosted box — owns the host it runs on: it provisions
the data root under its own sudo, converges the host tooling and installs
the lock, cold or warm, every job. The step above is this verb.

**A non-owning identity runs `dev deps install`.** A process on a host
someone else converged — the agent user ai-flow spawns inside a job, a
process inside a container the host provisioned — installs the checkout's
lock against a data root that already exists. It does no host work.

`dev deps install` run as the runner user on a cold runner fails with
`Permission denied @ dir_s_mkdir - /var/lib/dev`: the data root was never
provisioned, and this verb does not provision it. That failure calls for
`dev up`, not for a permission grant.

When copying a workflow precedent: the runner user's step is `uses:
d3mlabs/dev/up@main`. A `dev deps install` in a workflow belongs to the
agent user's step, never to the runner's.

#### The checkpoint

A hosted runner's disk does not persist across jobs, so its warmth is a
**checkpoint**: a custom runner image of the disk after `dev up`, minted
by a `main`-only job. cellbound-3d's `ci.yml` is the reference.

- **The project's jobs**: the two steps above, then the project's
  commands. A job neither knows nor declares that it runs on a
  checkpoint; on one, the install is skipped and `dev up` is a probe.
- **checkpoint**: `needs:` the project's jobs; a job-level `if:` for
  `main` and for a lock file having changed; `snapshot: <image-name>`;
  body = the same two steps → `dev cache gc` → `docker logout` → empty
  the checkout (`find "$GITHUB_WORKSPACE" -mindepth 1 -delete`). The
  captured disk holds the data root, Linuxbrew and dev, nothing else.
- **Once, by hand**: enable image generation on the runner; let `main`
  mint the first version; bind the runner to the image at `latest`
  (`PATCH /orgs/<org>/actions/hosted-runners/<id>` with
  `image_source=custom image_id=<id> image_version=latest`).

A custom image is a block image of the whole disk, takes hours to
provision and is billed for as long as it is kept, so the job runs only
when a lock moved and an hourly workflow keeps the newest Ready version
and deletes the rest. Both are in cellbound-3d's `.github/workflows/`.
